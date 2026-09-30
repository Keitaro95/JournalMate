/**
 * チャレンジの発行とセッションの開始。
 *
 * 流れ:
 *   POST /v1/challenge            → チャレンジ（署名付き・5 分）
 *   POST /v1/session  初回        → attestation を検証し、端末の公開鍵を保存
 *   POST /v1/session  2 回目以降  → assertion を検証（鍵の持ち主であることの証明）
 *   → 24 時間の JWT を返す
 *
 * `appUserId` は**端末 ID**（アプリが Keychain の「この端末限定」に置いた UUID。
 * RevenueCat の appUserID も同じ値）。契約・使用量・無料枠・トライアルの台帳は全部これで引く。
 *
 * **keyId と端末 ID を結びつける**のが肝。App Attest が言えるのは
 * 「本物のアプリである」ことまでで、「どの端末か」ではない。1 つの鍵で
 * 次々と別の端末 ID を名乗って枠を食い潰すのを、この結びつけで止める。
 * 入れ直すと鍵（keyId）は作り直されるが、端末 ID は同じなので、新しい鍵が同じ端末 ID に結びつく。
 */

import { fromBase64, fromBase64Url, timingSafeEqual, toBase64, toBase64Url, utf8 } from "./bytes";
import { verifyAssertion, verifyAttestation } from "./attest";
import { CHALLENGE_TTL_SECONDS, Env, SESSION_TTL_SECONDS } from "./config";
import { badRequest, json, unauthorized } from "./http";
import { issue } from "./jwt";

interface DeviceKey {
  /** SPKI（base64）。 */
  publicKey: string;
  counter: number;
  appUserId: string;
}

interface SessionRequest {
  appUserId?: string;
  keyId?: string;
  attestation?: string;
  assertion?: string;
  challenge?: string;
}

const deviceKey = (keyId: string) => `key:${keyId}`;

/**
 * チャレンジは**保存しない**。「発行時刻.乱数」に HMAC の署名を付けて渡し、戻ってきたら
 * 署名と期限だけを確かめる。
 *
 * 以前は KV に置いて使い捨てにしていたが、このエンドポイントは認証なしで呼べるので、
 * 連打されると KV の書き込み枠（無料プランで 1 日 1,000 回）が尽き、全員がセッションを取れなくなる。
 *
 * 使い捨てでなくなっても、同じチャレンジの使い回しは App Attest 側で弾かれる:
 *   - attestation … 鍵（keyId）の登録は 1 度きり。登録済みなら assertion を求める
 *   - assertion …… 署名の回数（counter）が前回より進んでいなければ通さない
 */
export async function makeChallenge(secret: string, now = Date.now()): Promise<string> {
  const payload = `${Math.floor(now / 1000)}.${toBase64Url(crypto.getRandomValues(new Uint8Array(16)))}`;
  return `${payload}.${toBase64Url(await challengeSignature(payload, secret))}`;
}

/** 自分が発行し、期限内のチャレンジか。 */
export async function checkChallenge(value: string, secret: string, now = Date.now()): Promise<boolean> {
  const parts = value.split(".");
  if (parts.length !== 3) return false;
  const [issued, nonce, signature] = parts;

  const issuedAt = Number(issued);
  const age = Math.floor(now / 1000) - issuedAt;
  // 未来の時刻（時計のずれ）は 30 秒まで許す。
  if (!Number.isInteger(issuedAt) || age > CHALLENGE_TTL_SECONDS || age < -30) return false;

  let given: Uint8Array;
  try {
    given = fromBase64Url(signature);
  } catch {
    return false;
  }
  return timingSafeEqual(given, await challengeSignature(`${issued}.${nonce}`, secret));
}

async function challengeSignature(payload: string, secret: string): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw",
    utf8(secret) as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  // セッションの JWT と同じ鍵を使うので、用途の印を混ぜて署名を取り違えられないようにする。
  return new Uint8Array(
    await crypto.subtle.sign("HMAC", key, utf8(`challenge:${payload}`) as BufferSource),
  );
}

export async function issueChallenge(env: Env): Promise<Response> {
  const challenge = await makeChallenge(env.SESSION_SECRET);
  return json({ challenge, expiresIn: CHALLENGE_TTL_SECONDS });
}

/**
 * アプリ側が署名する平文。両側で同じ組み立て方にすること。
 * チャレンジだけでなく appUserID も混ぜて、署名を別のユーザーに使い回せなくする。
 */
export function clientData(challenge: string, appUserId: string): Uint8Array {
  return utf8(`${challenge}.${appUserId}`);
}

export async function startSession(request: Request, env: Env): Promise<Response> {
  const body = (await request.json().catch(() => ({}))) as SessionRequest;
  const { appUserId, keyId, challenge } = body;

  if (!appUserId || !keyId || !challenge) {
    return badRequest("appUserId / keyId / challenge が要ります");
  }

  if (!(await checkChallenge(challenge, env.SESSION_SECRET))) {
    return unauthorized("チャレンジが無効です");
  }

  if (env.ATTEST_MODE === "off") {
    // シミュレータには App Attest が無い。開発中だけ、合言葉で通す。
    if (!env.DEV_BYPASS_TOKEN
        || request.headers.get("x-dev-bypass") !== env.DEV_BYPASS_TOKEN) {
      return unauthorized("開発モードの合言葉が違います");
    }
    return await grant(appUserId, keyId, env);
  }

  const stored = await env.CACHE.get<DeviceKey>(deviceKey(keyId), "json");

  try {
    if (!stored) {
      if (!body.attestation) return badRequest("初回は attestation が要ります");

      const publicKey = await verifyAttestation({
        attestation: fromBase64(body.attestation),
        keyId: fromBase64(keyId),
        clientData: clientData(challenge, appUserId),
        appId: env.APP_ID,
        rootPem: env.APPLE_ROOT_CA_PEM,
      });
      await saveDevice(keyId, { publicKey: toBase64(publicKey), counter: 0, appUserId }, env);
    } else {
      if (!body.assertion) return badRequest("assertion が要ります");

      // この端末の鍵は、最初に名乗った appUserID のものとして使い続ける。
      if (stored.appUserId !== appUserId) {
        return unauthorized("この端末は別のアカウントに紐づいています");
      }

      const counter = await verifyAssertion({
        assertion: fromBase64(body.assertion),
        clientData: clientData(challenge, appUserId),
        publicKeySpki: fromBase64(stored.publicKey),
        appId: env.APP_ID,
        previousCounter: stored.counter,
      });
      await saveDevice(keyId, { ...stored, counter }, env);
    }
  } catch (error) {
    // 失敗の理由は返さない（攻撃者に手がかりを渡さない）。ログには残す。
    console.warn("attest failed", { keyId, message: (error as Error).message });
    return unauthorized("端末を確認できませんでした");
  }

  return await grant(appUserId, keyId, env);
}

async function grant(appUserId: string, keyId: string, env: Env): Promise<Response> {
  const { token, expiresAt } = await issue(
    { sub: appUserId, kid: keyId },
    env.SESSION_SECRET,
    SESSION_TTL_SECONDS,
  );
  return json({ token, expiresAt });
}

async function saveDevice(keyId: string, value: DeviceKey, env: Env): Promise<void> {
  // 端末の鍵は失効させない（アプリを消すまで有効）。TTL は付けない。
  await env.CACHE.put(deviceKey(keyId), JSON.stringify(value));
}
