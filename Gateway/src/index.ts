/**
 * JournalMate のゲートウェイ。
 *
 * やることは 4 つだけ:
 *   ① 本物のアプリからの呼び出しか（App Attest → セッション JWT）
 *   ② その人が契約中か、どのプランか（RevenueCat）。未契約ならトライアル中か、無料枠か
 *   ③ 今日の上限を超えていないか（Durable Object の台帳）
 *   ④ 渡してよい body か（モデル・max_tokens・大きさ）
 * 通れば Anthropic にそのまま中継し、SSE は素通しで返す。
 *
 * **Anthropic の API キーはここから外に出ない。** アプリには渡さない。
 */

import {
  Env,
  FREE_MODEL,
  FREE_POOL_DAILY,
  FREE_POOL_ID,
  FREE_POOL_MONTHLY,
  PLANS,
  TRIAL,
} from "./config";
import * as free from "./free";
import * as trial from "./trial";
import { badRequest, json, paymentRequired, rateLimited, tooMany, unauthorized } from "./http";
import { verify } from "./jwt";
import { toHex, utf8 } from "./bytes";
import {
  applyPlan,
  callAnthropic,
  estimateReserve,
  forceSingleTool,
  meterStream,
  readUsage,
  sanitize,
  weigh,
} from "./proxy";
import { issueChallenge, startSession } from "./session";
import { handleWebhook, parsePlan, subscriptionPlan } from "./subscription";
import type { LimitReason, Snapshot } from "./budget";

export { BudgetLedger } from "./budget";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("method not allowed", { status: 405 });
    }

    // 認証前のエンドポイントは IP で数える（認証後は `relay` / `startTrial` の中で端末 ID で数える）。
    if (url.pathname === "/v1/challenge" || url.pathname === "/v1/session") {
      const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
      if (!(await allow(env.IP_LIMITER, ip))) return rateLimited();
    }

    switch (url.pathname) {
      case "/v1/challenge":
        return await issueChallenge(env);
      case "/v1/session":
        return await startSession(request, env);
      case "/webhooks/revenuecat":
        return await handleWebhook(request, env);
      case "/v1/messages":
        return await relay(request, env, ctx);
      case "/v1/trial/start":
        return await startTrial(request, env);
      default:
        return new Response("not found", { status: 404 });
    }
  },
} satisfies ExportedHandler<Env>;

/** バインディングが無い環境（テスト・wrangler dev）では数えない。 */
async function allow(limiter: RateLimit | undefined, key: string): Promise<boolean> {
  if (!limiter) return true;
  return (await limiter.limit({ key })).success;
}

/**
 * Anthropic に渡す利用者の識別子。端末 ID そのものは渡さず、ハッシュにする。
 * 規約に反する使い方があったとき、Anthropic が「アカウント全体」ではなく
 * 「この利用者」の問題として扱えるようにするため。こちらもログから誰かを突き止められる。
 */
async function anthropicUserId(deviceId: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", utf8(`jm-user:${deviceId}`) as BufferSource));
  return toHex(digest).slice(0, 32);
}

async function authenticate(request: Request, env: Env) {
  const header = request.headers.get("authorization") ?? "";
  return header.startsWith("Bearer ")
    ? await verify(header.slice(7), env.SESSION_SECRET)
    : null;
}

/**
 * 無料トライアルを始める。すでに始めていればその状態を返す。
 * 使い終わった・この端末で使用済みなら 409（`scope` で理由を分ける）。
 */
async function startTrial(request: Request, env: Env): Promise<Response> {
  const claims = await authenticate(request, env);
  if (!claims) return unauthorized("セッションが無効です");
  if (!(await allow(env.USER_LIMITER, claims.sub))) return rateLimited();

  const result = await trial.start({
    deviceId: claims.sub,
    deviceToken: request.headers.get("x-device-token"),
    env,
  });
  if (!result.ok) {
    return json(
      {
        error: {
          type: "trial_unavailable",
          scope: result.reason,
          message:
            result.reason === "ended"
              ? "無料トライアルは終了しました"
              : "この端末では無料トライアルを使用済みです",
        },
      },
      409,
    );
  }
  return json({
    startedAt: result.status.startedAt,
    endsAt: result.status.endsAt,
    dailyLimit: TRIAL.daily,
  });
}

async function relay(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  // --- ① 呼び出し元 ---
  // claims.sub が**端末 ID**。契約・使用量・無料枠・トライアルは全部これで引く
  // （RevenueCat の appUserID も同じ値）。App Attest の鍵（kid）は本物のアプリかの確認にだけ使う。
  const claims = await authenticate(request, env);
  if (!claims) return unauthorized("セッションが無効です");
  if (!(await allow(env.USER_LIMITER, claims.sub))) return rateLimited();

  // --- ② 契約 → トライアル → 無料枠の順に見る ---
  const feature = request.headers.get("x-feature") ?? "";
  const deviceToken = request.headers.get("x-device-token");
  const plan = await subscriptionPlan(claims.sub, env, parsePlan(request.headers.get("x-plan")));
  const onTrial = !plan && (await trial.current(claims.sub, env)).active;

  let verdict: free.FreeVerdict | null = null;
  if (!plan && !onTrial) {
    verdict = await free.judge({ feature, deviceId: claims.sub, deviceToken, env });
    if (!verdict.allowed) {
      switch (verdict.reason) {
        case "not_free_feature":
          return paymentRequired();
        case "exhausted":
          return paymentRequired("今月の無料枠を使い切りました", "free_exhausted");
        case "device_used":
          // 入れ直して枠を作り直そうとした場合もここに来る。
          return paymentRequired("この端末の今月ぶんは使用済みです", "device_used");
      }
    }
  }

  // --- ④ body（③ の見積もりに必要なので先に検査する）---
  const raw = await request.text();
  if (raw.length === 0) return badRequest("本文がありません");

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return badRequest("本文が JSON ではありません");
  }

  const checked = sanitize(parsed, raw.length);
  if (!checked.ok) return badRequest(checked.reason);

  // モデルは指定に関わらずこちらで決める。
  // 無料は Haiku と出力上限、トライアルは Haiku、契約者はプランのモデル。
  const limited = verdict ? free.applyFreeLimits(checked.body) : null;
  const chosen =
    limited?.body ??
    (plan ? applyPlan(checked.body, plan) : onTrial ? trial.applyTrial(checked.body) : checked.body);
  // Haiku は道具の指示を無視して地の文で答えることがあるので、道具を強制する。
  const forced = chosen.model === FREE_MODEL ? forceSingleTool(chosen) : chosen;
  // metadata はアプリからは受け取らない（ALLOWED_KEYS に無い）。こちらで付ける。
  const body: Record<string, unknown> = {
    ...forced,
    metadata: { user_id: await anthropicUserId(claims.sub) },
  };
  // 押さえる量は、プランごとに縛ったあとの max_tokens で見積もる（トライアルは 3,000 まで）。
  const maxTokens = typeof body.max_tokens === "number" ? body.max_tokens : checked.maxTokens;

  // --- ③ 上限：始める前に max_tokens ぶんを押さえる ---
  // 契約者は自分の台帳（上限はプランごと）、トライアルは端末の鍵ごとの台帳、
  // 無料枠は**全体**の共有プールに押さえる。
  const ledger = env.BUDGET.get(
    env.BUDGET.idFromName(
      verdict ? FREE_POOL_ID : onTrial ? trial.ledgerName(claims.sub) : claims.sub,
    ),
  );
  const amount = estimateReserve(raw.length, maxTokens);

  const reserved = (await (
    await ledger.fetch("https://ledger/reserve", {
      method: "POST",
      body: JSON.stringify({
        amount,
        // トライアルは 7 日間の合計（total）で縛る。台帳 `trial:<端末 ID>` はトライアル専用なので、
        // 台帳の全期間の合計 ＝ トライアル期間の合計になる。月をまたいでも数え直さない。
        limits: plan
          ? { daily: PLANS[plan].daily, monthly: PLANS[plan].monthly }
          : onTrial
            ? { daily: TRIAL.daily, monthly: TRIAL.total, total: TRIAL.total }
            : { daily: FREE_POOL_DAILY, monthly: FREE_POOL_MONTHLY },
      }),
    })
  ).json()) as
    | { ok: true; holdId: string; snapshot: Snapshot }
    | { ok: false; reason: LimitReason; snapshot: Snapshot };

  if (!reserved.ok) return tooMany(reserved.reason, reserved.snapshot.resetAt);

  const settle = async (weighted: number) => {
    await ledger.fetch("https://ledger/settle", {
      method: "POST",
      body: JSON.stringify({ holdId: reserved.holdId, weighted }),
    });
  };

  // --- 中継 ---
  const upstream = await callAnthropic(body, env.ANTHROPIC_API_KEY, env.ANTHROPIC_WORKSPACE_ID);
  const budgetHeaders = verdict
    ? freeHeaders(verdict.used, verdict.limit)
    : snapshotHeaders(reserved.snapshot);

  /** 成功した呼び出しだけ、無料枠の回数を 1 つ使う。 */
  const consumeFree = async () => {
    if (!verdict?.allowed) return;
    const used = await free.consume({
      feature,
      deviceId: claims.sub,
      deviceToken,
      markDevice: verdict.markDevice,
      env,
    });
    console.log("free call", { feature, used, limit: verdict.limit });
  };

  if (!upstream.ok) {
    // 呼べていないので押さえを返す。エラーの本文はそのまま通す。
    ctx.waitUntil(settle(0));
    return new Response(upstream.body, {
      status: upstream.status,
      headers: { "content-type": upstream.headers.get("content-type") ?? "application/json" },
    });
  }

  if (checked.stream && upstream.body) {
    const metered = meterStream(upstream.body, (usage) => {
      ctx.waitUntil(settle(weigh(usage)));
      ctx.waitUntil(consumeFree());
    });
    return new Response(metered, {
      status: 200,
      headers: {
        "content-type": upstream.headers.get("content-type") ?? "text/event-stream",
        "cache-control": "no-cache",
        ...budgetHeaders,
      },
    });
  }

  const payload = (await upstream.json()) as Record<string, unknown>;
  ctx.waitUntil(settle(weigh(readUsage(payload.usage))));
  ctx.waitUntil(consumeFree());
  return json(payload, 200, budgetHeaders);
}

/**
 * 無料枠の残りをアプリに知らせる。アプリ側の `feature_usage` はこれで上書きする
 * （入れ直して 0 に戻った表示を、サーバの数字に合わせ直すため）。
 * `used` はこの呼び出しを数える**前**の値なので 1 を足して返す。
 */
function freeHeaders(used: number, limit: number): Record<string, string> {
  return {
    "x-free-used": String(used + 1),
    "x-free-limit": String(limit),
  };
}

/** 残量をアプリに知らせる。**日付の計算はアプリにさせない**（端末の時計に依らせない）。 */
function snapshotHeaders(snapshot: Snapshot): Record<string, string> {
  return {
    "x-budget-limit": String(snapshot.dailyLimit),
    "x-budget-used": String(snapshot.dailyUsed),
    "x-budget-reset": String(snapshot.resetAt),
  };
}
