/**
 * 未契約者の無料枠。
 *
 * 数えるのは**回数**（機能ごと・月 20 回）。トークンの上限（契約者向け）とは別の軸。
 *
 * 入れ直しで枠を戻させないために、2 つを組み合わせる。
 *
 *   1. **DeviceCheck のビット** … 端末に紐づき、アプリを削除しても Apple 側に残る。
 *      「この端末は今月の無料枠を開始した」を覚える
 *   2. **台帳の回数** … 端末 ID ごとに「20 回のうち何回使ったか」を数える
 *
 * 端末 ID はアプリを入れ直しても変わらない（Keychain の「この端末限定」に置く）ので、
 * 入れ直しても台帳の回数はそのまま続く。端末を初期化して端末 ID まで消えたときは
 * 台帳が白紙になるが、ビットは残っているので「開始済み」と分かり、今月ぶんはもう渡さない。
 * 月が変わればビットが古くなって自動で戻る。
 *
 * DeviceCheck が未設定のときは 2 だけが効く（＝入れ直しで戻る）。
 * その場合も共有プール（`FREE_POOL_*`）が全体の出費を抑える。
 */

import { monthKey } from "./budget";
import {
  DEVICE_UNBOUND_FREE_FEATURES,
  Env,
  FREE_FEATURES,
  FREE_MAX_TOKENS,
  FREE_MODEL,
  MAX_TOKENS_CAP,
} from "./config";
import * as deviceCheck from "./devicecheck";

export type FreeVerdict =
  | { allowed: true; used: number; limit: number; markDevice: boolean }
  | { allowed: false; reason: "not_free_feature" | "exhausted" | "device_used" };

/** その機能が無料で呼べるか。呼べるなら月あたりの回数。 */
export function freeLimit(feature: string): number | undefined {
  return FREE_FEATURES.get(feature);
}

/**
 * 無料の呼び出しは、アプリが何を指定してきてもモデルと出力上限をこちらで決める。
 * **1 回あたりを安くするのが、無料枠を開けられる条件**（荒らされても総額が小さい）。
 */
export function applyFreeLimits(body: Record<string, unknown>): {
  body: Record<string, unknown>;
  maxTokens: number;
} {
  const maxTokens = Math.min(
    FREE_MAX_TOKENS,
    typeof body.max_tokens === "number" ? body.max_tokens : MAX_TOKENS_CAP,
  );
  return { body: { ...body, model: FREE_MODEL, max_tokens: maxTokens }, maxTokens };
}

/**
 * 無料で 1 回呼んでよいかを決める。
 *
 * `markDevice` が true なら、呼び出しが成功したあとに DeviceCheck のビットを立てる
 * （この端末が今月ぶんを開始した印）。すでに行があるときは立てる必要がない。
 */
export async function judge(params: {
  feature: string;
  /** 端末 ID（セッションの sub）。台帳の行はこれで引く。 */
  deviceId: string;
  deviceToken: string | null;
  env: Env;
  now?: number;
}): Promise<FreeVerdict> {
  const limit = freeLimit(params.feature);
  if (limit === undefined) return { allowed: false, reason: "not_free_feature" };

  const env = params.env;
  const now = params.now ?? Date.now();
  const ledger = env.BUDGET.get(env.BUDGET.idFromName(`free:${params.deviceId}`));

  const { used } = (await (
    await ledger.fetch("https://ledger/free/used", {
      method: "POST",
      body: JSON.stringify({ feature: params.feature }),
    })
  ).json()) as { used: number };

  if (used >= limit) return { allowed: false, reason: "exhausted" };

  // すでに 1 回でも使っている ＝ この端末のぶんとして開始済み。端末の確認は要らない。
  if (used > 0) return { allowed: true, used, limit, markDevice: false };

  // 初回だけ端末を見る。入れ直して台帳を白紙にしても、ここで弾かれる。
  // 端末のビットに乗せない機能は、台帳の回数だけで決める。
  if (
    DEVICE_UNBOUND_FREE_FEATURES.has(params.feature) ||
    !deviceCheck.isConfigured(env) ||
    !params.deviceToken
  ) {
    return { allowed: true, used, limit, markDevice: false };
  }
  try {
    const bits = await deviceCheck.queryBits(params.deviceToken, env);
    if (deviceCheck.startedThisMonth(bits, monthKey(now))) {
      return { allowed: false, reason: "device_used" };
    }
  } catch (error) {
    // Apple 側が落ちているときに無料ユーザーを締め出さない。
    // 通してよい理由は、共有プールで全体の出費が抑えられているから。
    console.warn("devicecheck unavailable", { message: (error as Error).message });
    return { allowed: true, used, limit, markDevice: false };
  }

  return { allowed: true, used, limit, markDevice: true };
}

/** 呼び出しが成功したときだけ数える（失敗した通信で無料枠を減らさない）。 */
export async function consume(params: {
  feature: string;
  deviceId: string;
  deviceToken: string | null;
  markDevice: boolean;
  env: Env;
}): Promise<number> {
  const env = params.env;
  const ledger = env.BUDGET.get(env.BUDGET.idFromName(`free:${params.deviceId}`));

  const { used } = (await (
    await ledger.fetch("https://ledger/free/consume", {
      method: "POST",
      body: JSON.stringify({ feature: params.feature }),
    })
  ).json()) as { used: number };

  if (params.markDevice && params.deviceToken && deviceCheck.isConfigured(env)) {
    try {
      await deviceCheck.markStarted(params.deviceToken, env);
    } catch (error) {
      // ビットが立たなくても呼び出しそのものは成功している。次回また試みる。
      console.warn("devicecheck mark failed", { message: (error as Error).message });
    }
  }
  return used;
}
