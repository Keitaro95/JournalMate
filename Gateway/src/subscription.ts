/**
 * 購読の確認。
 *
 * 正は RevenueCat。ただし毎回 REST を叩くと遅いので、
 * **Webhook で押し込み、キャッシュを読む**のを基本にする。
 * キャッシュが無い・古いときだけ REST に問い合わせる。
 */

import { timingSafeEqual, utf8 } from "./bytes";
import {
  ENTITLEMENT,
  Env,
  MAX_ENTITLEMENT,
  Plan,
  SUBSCRIPTION_CACHE_SECONDS,
  SUBSCRIPTION_RECHECK_SECONDS,
} from "./config";

export interface SubscriptionState {
  /** 契約中のプラン。未契約・失効なら null。 */
  plan: Plan | null;
  /** 期限（epoch ミリ秒）。無期限のときは null。 */
  expiresAt: number | null;
  checkedAt: number;
}

const cacheKey = (appUserId: string) => `sub:${appUserId}`;

/** キャッシュが示すプラン。期限が過ぎていれば、plan があっても切れたものとして扱う。 */
function cachedPlan(state: SubscriptionState, now: number): Plan | null {
  return state.expiresAt === null || state.expiresAt > now ? state.plan : null;
}

/** アプリが申告する、いま契約しているプラン（RevenueCat SDK が知っている状態）。 */
export function parsePlan(value: string | null): Plan | null {
  return value === "pro" || value === "max" ? value : null;
}

/**
 * キャッシュを使ってよいか、RevenueCat に聞き直すべきか。
 *
 * キャッシュは 1 時間持つので、購入の直前に「未契約」が書かれていると、払ったのに
 * 最大 1 時間無料扱いになる（Webhook が届けば直るが、届く前や届かないときに困る）。
 * そこで**アプリが契約中だと申告し、それがキャッシュと食い違うときだけ**聞き直す。
 * Pro → Max の直後も同じ。申告は信用せず、あくまで聞き直すきっかけにだけ使う。
 * 聞き直しは 1 分に 1 回まで（申告を細工して毎回 RevenueCat を叩かせない）。
 */
export function shouldUseCache(
  state: SubscriptionState | null,
  claimed: Plan | null,
  now: number,
): boolean {
  if (!state) return false;
  const age = now - state.checkedAt;
  if (age >= SUBSCRIPTION_CACHE_SECONDS * 1000) return false;
  if (claimed && claimed !== cachedPlan(state, now) && age >= SUBSCRIPTION_RECHECK_SECONDS * 1000) {
    return false;
  }
  return true;
}

/** 契約中のプラン。未契約なら null。`claimed` はアプリの申告（聞き直すきっかけにだけ使う）。 */
export async function subscriptionPlan(
  appUserId: string,
  env: Env,
  claimed: Plan | null = null,
  now = Date.now(),
): Promise<Plan | null> {
  const cached = await env.CACHE.get<SubscriptionState>(cacheKey(appUserId), "json");

  if (cached && shouldUseCache(cached, claimed, now)) {
    return cachedPlan(cached, now);
  }

  const fetched = await fetchFromRevenueCat(appUserId, env, now);
  await put(appUserId, fetched, env);
  return fetched.plan;
}

type Entitlements = Record<string, { expires_date?: string | null }> | undefined;

/**
 * RevenueCat のエンタイトルメントからプランを決める。`max` を先に見る
 * （Max の商品は `pro` にも紐づいているので、`pro` だけ見ると Max が Pro になる）。
 */
export function planFrom(entitlements: Entitlements, now: number): SubscriptionState {
  for (const [id, plan] of [[MAX_ENTITLEMENT, "max"], [ENTITLEMENT, "pro"]] as const) {
    const entitlement = entitlements?.[id];
    if (!entitlement) continue;
    // expires_date が無い ＝ 買い切り・無期限。
    const expiresAt = entitlement.expires_date ? Date.parse(entitlement.expires_date) : null;
    if (expiresAt === null || expiresAt > now) return { plan, expiresAt, checkedAt: now };
  }
  return { plan: null, expiresAt: null, checkedAt: now };
}

async function fetchFromRevenueCat(
  appUserId: string,
  env: Env,
  now: number,
): Promise<SubscriptionState> {
  const response = await fetch(
    `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(appUserId)}`,
    { headers: { Authorization: `Bearer ${env.RC_SECRET_KEY}` } },
  );

  // RevenueCat が落ちているときに全員を締め出さない。
  // 直前のキャッシュがあればそれを使い、無ければ「未契約」に倒す。
  if (!response.ok) {
    const stale = await env.CACHE.get<SubscriptionState>(cacheKey(appUserId), "json");
    if (stale) return { ...stale, checkedAt: now };
    return { plan: null, expiresAt: null, checkedAt: now };
  }

  const payload = (await response.json()) as {
    subscriber?: { entitlements?: Entitlements };
  };
  return planFrom(payload.subscriber?.entitlements, now);
}

async function put(appUserId: string, state: SubscriptionState, env: Env): Promise<void> {
  await env.CACHE.put(cacheKey(appUserId), JSON.stringify(state), {
    // 期限そのものより長くは残さない。
    expirationTtl: SUBSCRIPTION_CACHE_SECONDS * 6,
  });
}

/** 解約・失効・更新は Webhook で届く。届いた時点でキャッシュを直す。 */
const REVOKING_EVENTS = new Set(["EXPIRATION", "REFUND", "SUBSCRIPTION_PAUSED", "TRANSFER"]);

export async function handleWebhook(request: Request, env: Env): Promise<Response> {
  // 一致するまでの時間から秘密を 1 文字ずつ当てられないよう、比較にかかる時間を揃える。
  const given = utf8(request.headers.get("authorization") ?? "");
  if (!env.RC_WEBHOOK_SECRET || !timingSafeEqual(given, utf8(env.RC_WEBHOOK_SECRET))) {
    return new Response("unauthorized", { status: 401 });
  }

  const payload = (await request.json()) as {
    event?: { type?: string; app_user_id?: string; expiration_at_ms?: number };
  };
  const event = payload.event;
  if (!event?.app_user_id || !event.type) return new Response("ignored", { status: 202 });

  const now = Date.now();
  // 失効は RevenueCat に聞き直すまでもなく止める。それ以外（購入・更新・Pro ⇄ Max の変更）は
  // イベントからプランを組み立てず、RevenueCat に聞き直して正の状態を書く。
  const state = REVOKING_EVENTS.has(event.type)
    ? { plan: null, expiresAt: event.expiration_at_ms ?? null, checkedAt: now }
    : await fetchFromRevenueCat(event.app_user_id, env, now);

  await put(event.app_user_id, state, env);
  return new Response("ok");
}
