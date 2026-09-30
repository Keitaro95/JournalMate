/**
 * 1 ユーザーぶんのトークン台帳。**上限の根拠はここにしかない**。
 *
 * KV ではなく Durable Object に置く理由: KV は結果整合なので、同時に飛んできた
 * リクエストが同じ残量を読んで両方通り、上限を越える。DO はユーザー単位で
 * 直列化されるので数え落ちが起きない。
 *
 * 仮押さえ（reserve）→ 精算（settle）の 2 段にする理由: ストリーミングは
 * 走り出すと止められないので、始める前に max_tokens ぶんを押さえておかないと
 * 1 回の呼び出しで上限を大きく飛び越える。
 */

import { HOLD_TTL_MS, PLANS } from "./config";

export interface Hold {
  id: string;
  amount: number;
  at: number;
}

export interface LedgerState {
  dailyUsed: number;
  monthlyUsed: number;
  /** 台帳ができてからの合計。日や月では戻らない（トライアルの 7 日間の合計に使う）。 */
  totalUsed: number;
  holds: Hold[];
}

export interface Snapshot {
  dailyUsed: number;
  dailyLimit: number;
  monthlyUsed: number;
  monthlyLimit: number;
  /** 日次の枠が戻る時刻（UTC 翌日 0 時、epoch 秒）。 */
  resetAt: number;
}

export interface ReserveResult {
  ok: boolean;
  /** 上限に当たった理由。画面にはそのまま出さず、429 の本文に入れる。 */
  reason?: LimitReason;
  holdId?: string;
  state: LedgerState;
  snapshot: Snapshot;
}

export interface Limits {
  daily: number;
  monthly: number;
  /**
   * 台帳の全期間を通した上限。トライアルのように「期間の合計」で縛るときだけ渡す。
   * 月の枠で代用すると、月をまたいだ時点で数え直されてしまうため別に持つ。
   */
  total?: number;
}

export type LimitReason = "daily" | "monthly" | "total";

/**
 * 無料枠の消費数。トークンではなく**回数**を、機能ごと・月ごとに数える。
 * 月が変われば `month` が変わるので、自動的に 0 から数え直す。
 */
export interface FreeCounts {
  month: string;
  byFeature: Record<string, number>;
}

export function emptyCounts(month: string): FreeCounts {
  return { month, byFeature: {} };
}

/** 保存してある月が今と違えば捨てる（月次リセットを別の仕組みに持たせない）。 */
export function countsFor(stored: FreeCounts | undefined, month: string): FreeCounts {
  return stored && stored.month === month ? stored : emptyCounts(month);
}

export function usedCount(counts: FreeCounts, feature: string): number {
  return counts.byFeature[feature] ?? 0;
}

export function consumeCount(counts: FreeCounts, feature: string): FreeCounts {
  return {
    month: counts.month,
    byFeature: { ...counts.byFeature, [feature]: usedCount(counts, feature) + 1 },
  };
}

/** 呼び出し側が上限を渡さなかったとき。安い方（Pro）に倒す。 */
export const defaultLimits: Limits = { daily: PLANS.pro.daily, monthly: PLANS.pro.monthly };

export function emptyState(): LedgerState {
  return { dailyUsed: 0, monthlyUsed: 0, totalUsed: 0, holds: [] };
}

/** 保存してある状態を今に合わせる。日・月が変わればその桁だけ 0 に戻し、合計は戻さない。 */
export function restore(
  saved: { day: string; month: string; state: Partial<LedgerState> } | undefined,
  now: number,
): LedgerState {
  if (!saved) return emptyState();
  return {
    dailyUsed: saved.day === dayKey(now) ? (saved.state.dailyUsed ?? 0) : 0,
    monthlyUsed: saved.month === monthKey(now) ? (saved.state.monthlyUsed ?? 0) : 0,
    totalUsed: saved.state.totalUsed ?? 0,
    holds: saved.state.holds ?? [],
  };
}

/** UTC で日と月のキーを作る。端末のタイムゾーンは信用しない（動かせば枠が戻るため）。 */
export function dayKey(now: number): string {
  return new Date(now).toISOString().slice(0, 10);
}

export function monthKey(now: number): string {
  return new Date(now).toISOString().slice(0, 7);
}

/** 翌 0 時（UTC）。アプリにはこれを返し、アプリ側では日付を計算させない。 */
export function resetAt(now: number): number {
  const next = new Date(now);
  next.setUTCHours(24, 0, 0, 0);
  return Math.floor(next.getTime() / 1000);
}

/**
 * 台帳の計算そのもの。ストレージを触らない純粋関数として書き、
 * DO の外（テスト）からも同じものを動かせるようにする。
 */
export class Ledger {
  constructor(private limits: Limits = defaultLimits) {}

  /** 期限切れの仮押さえを捨てる。落ちた接続のぶんが永久に居座らないように。 */
  prune(state: LedgerState, now: number): LedgerState {
    return { ...state, holds: state.holds.filter((hold) => now - hold.at < HOLD_TTL_MS) };
  }

  held(state: LedgerState): number {
    return state.holds.reduce((sum, hold) => sum + hold.amount, 0);
  }

  reserve(state: LedgerState, amount: number, now: number, holdId: string): ReserveResult {
    const pruned = this.prune(state, now);
    const held = this.held(pruned);

    if (pruned.dailyUsed + held + amount > this.limits.daily) {
      return { ok: false, reason: "daily", state: pruned, snapshot: this.snapshot(pruned, now) };
    }
    if (pruned.monthlyUsed + held + amount > this.limits.monthly) {
      return { ok: false, reason: "monthly", state: pruned, snapshot: this.snapshot(pruned, now) };
    }
    if (this.limits.total !== undefined && pruned.totalUsed + held + amount > this.limits.total) {
      return { ok: false, reason: "total", state: pruned, snapshot: this.snapshot(pruned, now) };
    }

    const next: LedgerState = {
      ...pruned,
      holds: [...pruned.holds, { id: holdId, amount, at: now }],
    };
    return { ok: true, holdId, state: next, snapshot: this.snapshot(next, now) };
  }

  /**
   * 仮押さえを外し、実測ぶんを積む。
   * 押さえが見つからなくても実測は必ず積む（期限切れで消えていても、
   * 生成されたぶんは実際に課金されているため）。
   */
  settle(state: LedgerState, holdId: string, weighted: number, now: number): LedgerState {
    const pruned = this.prune(state, now);
    return {
      dailyUsed: pruned.dailyUsed + Math.max(0, weighted),
      monthlyUsed: pruned.monthlyUsed + Math.max(0, weighted),
      totalUsed: pruned.totalUsed + Math.max(0, weighted),
      holds: pruned.holds.filter((hold) => hold.id !== holdId),
    };
  }

  snapshot(state: LedgerState, now: number): Snapshot {
    return {
      dailyUsed: state.dailyUsed,
      dailyLimit: this.limits.daily,
      monthlyUsed: state.monthlyUsed,
      monthlyLimit: this.limits.monthly,
      resetAt: resetAt(now),
    };
  }
}

/**
 * Durable Object 側。保存と直列化だけを受け持ち、計算は `Ledger` に任せる。
 *
 * 日と月のキーを保存時に見て、変わっていたらその桁だけ 0 に戻す。
 * 「いつリセットするか」を別の仕組み（cron や alarm）に持たせない。
 */
export class BudgetLedger implements DurableObject {
  private ledger = new Ledger();

  constructor(private state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const now = Date.now();

    // 同じ DO への同時アクセスは直列化されるので、read → write の間に割り込まれない。
    return await this.state.blockConcurrencyWhile(async () => {
      const stored = await this.load(now);

      switch (url.pathname) {
        case "/reserve": {
          const { amount, limits } = (await request.json()) as {
            amount: number;
            /** プランごとの上限や共有プールの上限。無ければ Pro の上限。 */
            limits?: Limits;
          };
          const holdId = crypto.randomUUID();
          const ledger = limits ? new Ledger(limits) : this.ledger;
          const result = ledger.reserve(stored, Math.max(0, amount | 0), now, holdId);
          await this.save(result.state, now);
          return Response.json(result.ok
            ? { ok: true, holdId: result.holdId, snapshot: result.snapshot }
            : { ok: false, reason: result.reason, snapshot: result.snapshot });
        }

        case "/settle": {
          const { holdId, weighted } = (await request.json()) as {
            holdId: string;
            weighted: number;
          };
          const next = this.ledger.settle(stored, holdId, weighted | 0, now);
          await this.save(next, now);
          return Response.json({ ok: true, snapshot: this.ledger.snapshot(next, now) });
        }

        case "/snapshot":
          return Response.json({ ok: true, snapshot: this.ledger.snapshot(stored, now) });

        // --- 無料トライアル（開始時刻だけ持つ。期間の判定は trial.ts）---

        case "/trial/get": {
          const startedAt = (await this.state.storage.get<number>("trialStartedAt")) ?? null;
          return Response.json({ ok: true, startedAt });
        }

        case "/trial/start": {
          // 先に書かれていればそれを返す（二度押しで開始時刻を動かさない）。
          const { now: at } = (await request.json()) as { now: number };
          const startedAt = (await this.state.storage.get<number>("trialStartedAt")) ?? at;
          await this.state.storage.put("trialStartedAt", startedAt);
          return Response.json({ ok: true, startedAt });
        }

        // --- 無料枠（回数）---

        case "/free/used": {
          const { feature } = (await request.json()) as { feature: string };
          const counts = await this.loadCounts(now);
          return Response.json({ ok: true, used: usedCount(counts, feature) });
        }

        case "/free/consume": {
          const { feature } = (await request.json()) as { feature: string };
          const counts = consumeCount(await this.loadCounts(now), feature);
          await this.state.storage.put("free", counts);
          return Response.json({ ok: true, used: usedCount(counts, feature) });
        }

        default:
          return new Response("not found", { status: 404 });
      }
    });
  }

  /** 保存してある日・月が今と違えば、その桁を 0 から数え直す（合計は戻さない）。 */
  private async load(now: number): Promise<LedgerState> {
    return restore(
      await this.state.storage.get<{ day: string; month: string; state: LedgerState }>("ledger"),
      now,
    );
  }

  private async loadCounts(now: number): Promise<FreeCounts> {
    return countsFor(await this.state.storage.get<FreeCounts>("free"), monthKey(now));
  }

  private async save(state: LedgerState, now: number): Promise<void> {
    await this.state.storage.put("ledger", {
      day: dayKey(now),
      month: monthKey(now),
      state,
    });
  }
}
