/**
 * アプリ内の無料トライアル（7 日間・Haiku）。App Store を通さない独立したプランで、
 * 終われば無料に戻る。自動課金はしない。
 *
 * 記録は 2 か所に置く。
 *   - 台帳（Durable Object `trial:<端末 ID>`）… いつ始めたか。期間の判定はこれで行う
 *   - DeviceCheck の bit1 ……………………… この端末で使ったか。端末を初期化してもやり直させないため
 *
 * 端末 ID はアプリを入れ直しても変わらないので、期間中に入れ直してもトライアルはそのまま続く。
 * 端末を初期化して端末 ID まで消えても、bit1 が残っているので新しく始めることはできない。
 */

import { monthKey } from "./budget";
import { Env, TRIAL } from "./config";
import * as deviceCheck from "./devicecheck";

const DAY_MS = 24 * 60 * 60 * 1000;

export interface TrialStatus {
  /** 始めた時刻（epoch ミリ秒）。始めていなければ null。 */
  startedAt: number | null;
  endsAt: number | null;
  active: boolean;
}

export function status(startedAt: number | null, now: number): TrialStatus {
  if (startedAt === null) return { startedAt: null, endsAt: null, active: false };
  const endsAt = startedAt + TRIAL.days * DAY_MS;
  return { startedAt, endsAt, active: now < endsAt };
}

/**
 * トライアル中の呼び出しは、アプリが何を指定してきても Haiku で呼び、出力も `TRIAL.maxTokens` までにする。
 * 小さい max_tokens はそのまま尊重する。
 */
export function applyTrial(body: Record<string, unknown>): Record<string, unknown> {
  const requested = typeof body.max_tokens === "number" ? body.max_tokens : TRIAL.maxTokens;
  return { ...body, model: TRIAL.model, max_tokens: Math.min(requested, TRIAL.maxTokens) };
}

export const ledgerName = (deviceId: string) => `trial:${deviceId}`;

function ledger(deviceId: string, env: Env): DurableObjectStub {
  return env.BUDGET.get(env.BUDGET.idFromName(ledgerName(deviceId)));
}

/** 台帳にある開始時刻から、今の状態を返す。 */
export async function current(deviceId: string, env: Env, now = Date.now()): Promise<TrialStatus> {
  const { startedAt } = (await (
    await ledger(deviceId, env).fetch("https://ledger/trial/get", { method: "POST" })
  ).json()) as { startedAt: number | null };
  return status(startedAt, now);
}

export type StartResult =
  | { ok: true; status: TrialStatus }
  | { ok: false; reason: "ended" | "device_used" };

/**
 * トライアルを始める。すでに始めていれば、その状態をそのまま返す（何度押しても同じ）。
 */
export async function start(params: {
  /** 端末 ID（セッションの sub）。 */
  deviceId: string;
  deviceToken: string | null;
  env: Env;
  now?: number;
}): Promise<StartResult> {
  const { deviceId, deviceToken, env } = params;
  const now = params.now ?? Date.now();

  const existing = await current(deviceId, env, now);
  if (existing.startedAt !== null) {
    return existing.active ? { ok: true, status: existing } : { ok: false, reason: "ended" };
  }

  // 端末で見る。入れ直して台帳を白紙にしても、ここで弾かれる。
  let bits: deviceCheck.BitState | null = null;
  if (deviceCheck.isConfigured(env) && deviceToken) {
    try {
      bits = await deviceCheck.queryBits(deviceToken, env);
      if (deviceCheck.trialUsed(bits)) return { ok: false, reason: "device_used" };
    } catch (error) {
      // Apple 側が落ちているときは通す。1 人あたりの原価は Haiku で約 $0.14 と小さい。
      console.warn("devicecheck unavailable", { message: (error as Error).message });
    }
  }

  const { startedAt } = (await (
    await ledger(deviceId, env).fetch("https://ledger/trial/start", {
      method: "POST",
      body: JSON.stringify({ now }),
    })
  ).json()) as { startedAt: number };

  if (bits && deviceToken) {
    try {
      await deviceCheck.markTrial(deviceToken, env, bits, monthKey(now));
    } catch (error) {
      // 印が付かなくても開始は取り消さない。台帳の記録で期間は守られる。
      console.warn("devicecheck mark failed", { message: (error as Error).message });
    }
  }
  return { ok: true, status: status(startedAt, now) };
}
