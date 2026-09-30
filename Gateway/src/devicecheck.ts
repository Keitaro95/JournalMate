/**
 * DeviceCheck。**端末に紐づく 2 ビットを Apple のサーバに置く**仕組み。
 *
 * これが無料枠の要。App Attest の鍵も RevenueCat の匿名 ID も、アプリを消せば
 * 作り直されるので「入れ直せば毎月 20 回がまた来る」を塞げない。
 * DeviceCheck のビットは**アプリを削除しても残る**（Apple 側に、端末 × 開発者アカウントで
 * 保存される）。Apple の用途説明にある「プロモーション特典をすでに受け取った端末の識別」
 * がそのままこれ。
 *
 * 持てるのは 2 ビットと「最終更新月」だけなので、こう使う:
 *   bit0 … この端末は無料枠を開始した
 *   bit1 … この端末は無料トライアルを使った（一生に 1 回。月では戻らない）
 *   last_update_time（"2026-09"）… 最後にどちらかを書いた月
 *
 * **last_update_time は 2 ビットで共有**なので、片方を書くときはもう片方を壊さないこと。
 * 書き込みの中身は `bitsForFreeMark` / `bitsForTrialMark` の純粋関数で決める。
 * 月が変われば last_update_time が古くなるので、**月次リセットは自動で効く**。
 * 「20 回のうち何回使ったか」はこちらの台帳（`budget.ts`）で数える。
 */

import { fromBase64, toBase64Url, utf8 } from "./bytes";
import { Env } from "./config";

const PRODUCTION = "https://api.devicecheck.apple.com/v1";
const DEVELOPMENT = "https://api.development.devicecheck.apple.com/v1";

export interface BitState {
  bit0: boolean;
  bit1: boolean;
  /** "2026-09"。まだ一度も書いていない端末では null。 */
  lastUpdate: string | null;
}

/** DeviceCheck を使う設定が揃っているか。無ければ端末の見分けは効かない。 */
export function isConfigured(env: Env): boolean {
  return Boolean(env.DEVICECHECK_KEY_P8 && env.DEVICECHECK_KEY_ID && env.APPLE_TEAM_ID);
}

/**
 * この端末が、今月ぶんの無料枠をすでに開始しているか。
 *
 * 「開始した（bit0）」かつ「その記録が今月のもの」のときだけ true。
 * 先月に立てたビットは古いので、今月は新しく使える。
 */
export function startedThisMonth(state: BitState, month: string): boolean {
  return state.bit0 && state.lastUpdate === month;
}

/** この端末が無料トライアルを使ったか。 */
export function trialUsed(state: BitState): boolean {
  return state.bit1;
}

/** 無料枠を開始した印を付けるときに書く値。トライアルの印（bit1）は残す。 */
export function bitsForFreeMark(state: BitState): { bit0: boolean; bit1: boolean } {
  return { bit0: true, bit1: state.bit1 };
}

/**
 * トライアルの印を付けるときに書く値。
 *
 * 書けば last_update_time が今月になる。先月の bit0 をそのまま残すと
 * 「今月無料枠を開始した」に化けて、今月の無料枠を取り上げてしまう。
 * だから bit0 は**今月のものだけ**残す。
 */
export function bitsForTrialMark(state: BitState, month: string): { bit0: boolean; bit1: boolean } {
  return { bit0: startedThisMonth(state, month), bit1: true };
}

export async function queryBits(deviceToken: string, env: Env): Promise<BitState> {
  const response = await call("query_two_bits", deviceToken, env);

  // まだ一度も書いていない端末には、200 で「見つからない」旨の本文が返る。
  const text = await response.text();
  if (!response.ok) throw new Error(`devicecheck: query に失敗（${response.status}）${text}`);
  if (!text.trim().startsWith("{")) {
    return { bit0: false, bit1: false, lastUpdate: null };
  }

  const payload = JSON.parse(text) as {
    bit0?: boolean;
    bit1?: boolean;
    last_update_time?: string;
  };
  return {
    bit0: payload.bit0 === true,
    bit1: payload.bit1 === true,
    lastUpdate: payload.last_update_time ?? null,
  };
}

/** 無料枠を開始した印を付ける。次に入れ直されても、今月ぶんはもう渡さない。 */
export async function markStarted(deviceToken: string, env: Env): Promise<void> {
  // bit1（トライアル）を消さないよう、今の値を読んでから書く。
  await update(deviceToken, env, bitsForFreeMark(await queryBits(deviceToken, env)));
}

/** トライアルを使った印を付ける。`state` は直前に読んだ値。 */
export async function markTrial(
  deviceToken: string,
  env: Env,
  state: BitState,
  month: string,
): Promise<void> {
  await update(deviceToken, env, bitsForTrialMark(state, month));
}

async function update(
  deviceToken: string,
  env: Env,
  bits: { bit0: boolean; bit1: boolean },
): Promise<void> {
  const response = await call("update_two_bits", deviceToken, env, bits);
  if (!response.ok) {
    throw new Error(`devicecheck: update に失敗（${response.status}）${await response.text()}`);
  }
}

async function call(
  path: "query_two_bits" | "update_two_bits",
  deviceToken: string,
  env: Env,
  bits?: { bit0: boolean; bit1: boolean },
): Promise<Response> {
  const base = env.DEVICECHECK_ENV === "development" ? DEVELOPMENT : PRODUCTION;
  return await fetch(`${base}/${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      Authorization: `Bearer ${await appleToken(env)}`,
    },
    body: JSON.stringify({
      device_token: deviceToken,
      transaction_id: crypto.randomUUID(),
      timestamp: Date.now(),
      ...bits,
    }),
  });
}

/**
 * Apple に出す ES256 の JWT。App Store Connect で作った鍵（.p8）で署名する。
 * 有効期間は短くてよく、毎回作り直しても安い。
 */
async function appleToken(env: Env): Promise<string> {
  if (!isConfigured(env)) throw new Error("devicecheck: 鍵が設定されていません");

  const header = toBase64Url(
    utf8(JSON.stringify({ alg: "ES256", kid: env.DEVICECHECK_KEY_ID, typ: "JWT" })),
  );
  const payload = toBase64Url(
    utf8(JSON.stringify({ iss: env.APPLE_TEAM_ID, iat: Math.floor(Date.now() / 1000) })),
  );

  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      await signingKey(env.DEVICECHECK_KEY_P8 ?? ""),
      utf8(`${header}.${payload}`) as BufferSource,
    ),
  );
  return `${header}.${payload}.${toBase64Url(signature)}`;
}

/** .p8（PKCS#8 の PEM）を WebCrypto の鍵にする。 */
async function signingKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  return await crypto.subtle.importKey(
    "pkcs8",
    fromBase64(body) as BufferSource,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}
