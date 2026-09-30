import { describe, expect, it } from "vitest";

import { concat, fromBase64Url, toBase64Url, toHex } from "../src/bytes";
import {
  Ledger,
  consumeCount,
  countsFor,
  dayKey,
  emptyCounts,
  emptyState,
  restore,
  monthKey,
  resetAt,
  usedCount,
} from "../src/budget";
import { applyFreeLimits, freeLimit } from "../src/free";
import { PLANS, TRIAL } from "../src/config";
import { applyTrial, status as trialStatus } from "../src/trial";
import { forceSingleTool } from "../src/proxy";
import { parsePlan, planFrom, shouldUseCache } from "../src/subscription";
import {
  bitsForFreeMark,
  bitsForTrialMark,
  startedThisMonth,
  trialUsed,
} from "../src/devicecheck";
import { decodeCbor } from "../src/cbor";
import { derToRawSignature, extractNonce, parseAuthenticatorData } from "../src/attest";
import { issue, verify } from "../src/jwt";
import { checkChallenge, makeChallenge } from "../src/session";
import { rateLimited } from "../src/http";
import {
  addUsage,
  applyPlan,
  estimateReserve,
  meterStream,
  readUsage,
  sanitize,
  weigh,
} from "../src/proxy";

// ---------------------------------------------------------------- body の検査

describe("sanitize", () => {
  const valid = {
    model: "claude-sonnet-5",
    max_tokens: 1_000,
    messages: [{ role: "user", content: "こんにちは" }],
  };

  it("通す body はそのまま", () => {
    const result = sanitize(valid, 200);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.body.model).toBe("claude-sonnet-5");
  });

  it("許可していないモデルを弾く", () => {
    expect(sanitize({ ...valid, model: "gpt-4" }, 200).ok).toBe(false);
  });


  it("知らないキーは落とす（自前のプロキシとして使われないように）", () => {
    const result = sanitize({ ...valid, metadata: { user_id: "x" }, container: "y" }, 200);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.body.metadata).toBeUndefined();
      expect(result.body.container).toBeUndefined();
    }
  });

  it("max_tokens に上限を被せる", () => {
    const result = sanitize({ ...valid, max_tokens: 1_000_000 }, 200);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.maxTokens).toBe(8_000);
  });

  it("max_tokens が無いときは上限を使う", () => {
    const result = sanitize({ model: valid.model, messages: valid.messages }, 200);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.body.max_tokens).toBe(8_000);
  });

  it("大きすぎる本文を弾く", () => {
    expect(sanitize(valid, 10_000_000).ok).toBe(false);
  });

  it("messages が無ければ弾く", () => {
    expect(sanitize({ model: valid.model }, 200).ok).toBe(false);
    expect(sanitize({ model: valid.model, messages: [] }, 200).ok).toBe(false);
  });

  it("オブジェクト以外を弾く", () => {
    expect(sanitize("文字列", 10).ok).toBe(false);
    expect(sanitize([1, 2], 10).ok).toBe(false);
    expect(sanitize(null, 10).ok).toBe(false);
  });
});

// ---------------------------------------------------------------- 計量

describe("プラン（Pro / Max）", () => {
  const body = { model: "claude-opus-5", max_tokens: 1_000, messages: [] };

  it("Pro が Opus を指定しても Sonnet に差し替える", () => {
    expect(applyPlan(body, "pro").model).toBe("claude-sonnet-5");
  });

  it("Max は Opus で呼ぶ", () => {
    expect(applyPlan({ ...body, model: "claude-sonnet-5" }, "max").model).toBe("claude-opus-5");
  });

  it("max を先に見る（Max の商品は pro にも紐づいている）", () => {
    const now = Date.parse("2026-10-01T00:00:00Z");
    const later = "2026-11-01T00:00:00Z";
    expect(planFrom({ pro: { expires_date: later }, max: { expires_date: later } }, now).plan)
      .toBe("max");
    expect(planFrom({ pro: { expires_date: later } }, now).plan).toBe("pro");
  });

  it("期限切れの max は無視して pro を見る。どちらも切れていれば未契約", () => {
    const now = Date.parse("2026-10-01T00:00:00Z");
    const earlier = "2026-09-01T00:00:00Z";
    const later = "2026-11-01T00:00:00Z";
    expect(planFrom({ max: { expires_date: earlier }, pro: { expires_date: later } }, now).plan)
      .toBe("pro");
    expect(planFrom({ max: { expires_date: earlier } }, now).plan).toBeNull();
    expect(planFrom(undefined, now).plan).toBeNull();
  });

  // 上限は価格から逆算している。数字を触ったときに採算が崩れていないかをここで止める。
  it("月の上限を使い切っても、原価が手取りの取り決め以内に収まる", () => {
    const yenPerDollar = 148;
    const dollarsPerMillion: Record<string, number> = {
      "claude-sonnet-5": 2,
      "claude-opus-5": 5,
    };
    /** 税込の月額 → 消費税 10% と手数料 15% を引いた手取り。 */
    const proceeds = (price: number) => (price / 1.1) * 0.85;
    const costRatio = (plan: "pro" | "max", price: number) =>
      ((PLANS[plan].monthly / 1_000_000) * dollarsPerMillion[PLANS[plan].model] * yenPerDollar) /
      proceeds(price);

    expect(costRatio("pro", 770)).toBeLessThanOrEqual(0.3);
    expect(costRatio("max", 2_980)).toBeLessThanOrEqual(0.4);
  });

  describe("購読状態のキャッシュ", () => {
    const now = Date.parse("2026-10-01T12:00:00Z");
    const minute = 60 * 1000;
    const cached = (plan: "pro" | "max" | null, ageMs: number) => ({
      plan,
      expiresAt: null,
      checkedAt: now - ageMs,
    });

    it("1 時間はキャッシュを使う", () => {
      expect(shouldUseCache(cached("pro", 59 * minute), "pro", now)).toBe(true);
      expect(shouldUseCache(cached("pro", 60 * minute), "pro", now)).toBe(false);
      expect(shouldUseCache(null, null, now)).toBe(false);
    });

    it("購入直後: キャッシュは未契約でもアプリが契約中と言えば聞き直す", () => {
      expect(shouldUseCache(cached(null, 5 * minute), "pro", now)).toBe(false);
    });

    it("Pro → Max の直後も聞き直す", () => {
      expect(shouldUseCache(cached("pro", 5 * minute), "max", now)).toBe(false);
    });

    it("聞き直しは 1 分に 1 回まで（申告を細工して毎回叩かせない）", () => {
      expect(shouldUseCache(cached(null, 30 * 1000), "pro", now)).toBe(true);
    });

    it("アプリが何も言わなければ（無料）聞き直さない", () => {
      expect(shouldUseCache(cached(null, 30 * minute), null, now)).toBe(true);
    });

    it("申告は pro / max だけを受け取る", () => {
      expect(parsePlan("max")).toBe("max");
      expect(parsePlan("enterprise")).toBeNull();
      expect(parsePlan(null)).toBeNull();
    });
  });

  it("Max は Pro より多く使える", () => {
    expect(PLANS.max.daily).toBeGreaterThan(PLANS.pro.daily);
    expect(PLANS.max.monthly).toBeGreaterThan(PLANS.pro.monthly);
  });
});

describe("トークンの計量", () => {
  it("出力を重く、キャッシュを軽く数える", () => {
    expect(weigh({ input: 1_000, output: 1_000, cacheRead: 0 })).toBe(6_000);
    expect(weigh({ input: 0, output: 0, cacheRead: 10_000 })).toBe(1_000);
  });

  it("応答の usage を読む（欠けていても落ちない）", () => {
    expect(readUsage({ input_tokens: 5, output_tokens: 7, cache_read_input_tokens: 9 }))
      .toEqual({ input: 5, output: 7, cacheRead: 9 });
    expect(readUsage({ input_tokens: 5 })).toEqual({ input: 5, output: 0, cacheRead: 0 });
    expect(readUsage(undefined)).toEqual({ input: 0, output: 0, cacheRead: 0 });
  });

  it("足し合わせられる", () => {
    expect(addUsage({ input: 1, output: 2, cacheRead: 3 }, { input: 4, output: 5, cacheRead: 6 }))
      .toEqual({ input: 5, output: 7, cacheRead: 9 });
  });

  it("押さえる量は出力の上限を見込む（小さく見積もらない）", () => {
    expect(estimateReserve(300, 1_000)).toBe(100 + 5_000);
  });
});

describe("SSE の素通しと計量", () => {
  const sse = [
    'data: {"type":"message_start","message":{"usage":{"input_tokens":120}}}',
    'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"こん"}}',
    'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"にちは"}}',
    'data: {"type":"message_delta","usage":{"output_tokens":34}}',
    "",
  ].join("\n");

  const streamOf = (chunks: string[]) =>
    new ReadableStream<Uint8Array>({
      start(controller) {
        const encoder = new TextEncoder();
        for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
        controller.close();
      },
    });

  it("本文を変えずに流し、usage を拾う", async () => {
    let seen = { input: 0, output: 0, cacheRead: 0 };
    const out = meterStream(streamOf([sse]), (usage) => {
      seen = usage;
    });

    const text = await new Response(out).text();
    expect(text).toBe(sse);
    expect(seen).toEqual({ input: 120, output: 34, cacheRead: 0 });
  });

  it("チャンクが行の途中で切れても数えられる", async () => {
    let seen = { input: 0, output: 0, cacheRead: 0 };
    const half = Math.floor(sse.length / 2);
    const out = meterStream(streamOf([sse.slice(0, half), sse.slice(half)]), (usage) => {
      seen = usage;
    });

    expect(await new Response(out).text()).toBe(sse);
    expect(seen).toEqual({ input: 120, output: 34, cacheRead: 0 });
  });

  it("壊れた行があっても中継は止まらない", async () => {
    let called = false;
    const broken = 'data: {"type":"message_start"\ndata: {"type":"message_delta","usage":{"output_tokens":7}}\n';
    const out = meterStream(streamOf([broken]), (usage) => {
      called = true;
      expect(usage.output).toBe(7);
    });
    expect(await new Response(out).text()).toBe(broken);
    expect(called).toBe(true);
  });
});

// ---------------------------------------------------------------- 台帳

describe("Ledger", () => {
  const limits = { daily: 100_000, monthly: 1_000_000 };
  const ledger = new Ledger(limits);
  const now = Date.parse("2026-09-23T10:00:00Z");

  it("余裕があれば押さえられる", () => {
    const result = ledger.reserve(emptyState(), 10_000, now, "h1");
    expect(result.ok).toBe(true);
    expect(ledger.held(result.state)).toBe(10_000);
  });

  it("押さえたぶんも上限に数える（同時に走っても越えない）", () => {
    let state = emptyState();
    for (let i = 0; i < 10; i++) {
      const result = ledger.reserve(state, 10_000, now, `h${i}`);
      expect(result.ok).toBe(true);
      state = result.state;
    }
    expect(ledger.reserve(state, 1, now, "over").ok).toBe(false);
  });

  it("精算すると押さえが外れ、実測だけが残る", () => {
    const reserved = ledger.reserve(emptyState(), 40_000, now, "h1");
    const settled = ledger.settle(reserved.state, "h1", 1_200, now);
    expect(ledger.held(settled)).toBe(0);
    expect(settled.dailyUsed).toBe(1_200);
    expect(settled.monthlyUsed).toBe(1_200);
  });

  it("精算されなかった押さえは時間で捨てる", () => {
    const reserved = ledger.reserve(emptyState(), 40_000, now, "leaked");
    const later = now + 10 * 60 * 1000;
    expect(ledger.held(ledger.prune(reserved.state, later))).toBe(0);
  });

  it("押さえが消えていても実測は積む（生成されたぶんは課金されている）", () => {
    const settled = ledger.settle(emptyState(), "unknown", 900, now);
    expect(settled.dailyUsed).toBe(900);
  });

  it("日次と月次を別に見る", () => {
    const state = { dailyUsed: 0, monthlyUsed: limits.monthly, totalUsed: 0, holds: [] };
    const result = ledger.reserve(state, 10, now, "h");
    expect(result.ok).toBe(false);
    expect(result.reason).toBe("monthly");
  });

  it("日と月は UTC で切る", () => {
    // 日本時間の 23 日 9 時は UTC ではまだ 23 日 0 時。
    expect(dayKey(Date.parse("2026-09-23T00:00:00Z"))).toBe("2026-09-23");
    expect(monthKey(Date.parse("2026-09-23T00:00:00Z"))).toBe("2026-09");
    expect(resetAt(Date.parse("2026-09-23T23:59:00Z")))
      .toBe(Date.parse("2026-09-24T00:00:00Z") / 1000);
  });
});

// ---------------------------------------------------------------- セッション

describe("JWT", () => {
  const secret = "test-secret";

  it("発行したものを検証できる", async () => {
    const { token, expiresAt } = await issue({ sub: "user-1", kid: "key-1" }, secret, 3_600);
    const claims = await verify(token, secret);
    expect(claims?.sub).toBe("user-1");
    expect(claims?.kid).toBe("key-1");
    expect(claims?.exp).toBe(expiresAt);
  });

  it("別の鍵では通らない", async () => {
    const { token } = await issue({ sub: "user-1", kid: "key-1" }, secret, 3_600);
    expect(await verify(token, "別の鍵")).toBeNull();
  });

  it("中身を書き換えたら通らない", async () => {
    const { token } = await issue({ sub: "user-1", kid: "key-1" }, secret, 3_600);
    const [header, , signature] = token.split(".");
    const forged = toBase64Url(new TextEncoder().encode(
      JSON.stringify({ sub: "他人", kid: "key-1", exp: 9_999_999_999, iat: 0 }),
    ));
    expect(await verify(`${header}.${forged}.${signature}`, secret)).toBeNull();
  });

  it("期限切れは通らない", async () => {
    const { token } = await issue({ sub: "user-1", kid: "key-1" }, secret, 1);
    expect(await verify(token, secret, Date.now() + 5_000)).toBeNull();
  });

  it("形が違えば通らない", async () => {
    expect(await verify("not-a-token", secret)).toBeNull();
  });
});

// ---------------------------------------------------------------- App Attest の部品

describe("CBOR", () => {
  it("マップ・バイト列・整数を読む", () => {
    // {"fmt": "x", "n": 1, "b": h'0102'}
    const bytes = new Uint8Array([
      0xa3,
      0x63, 0x66, 0x6d, 0x74, 0x61, 0x78,
      0x61, 0x6e, 0x01,
      0x61, 0x62, 0x42, 0x01, 0x02,
    ]);
    const value = decodeCbor(bytes) as Record<string, unknown>;
    expect(value.fmt).toBe("x");
    expect(value.n).toBe(1);
    expect(value.b).toEqual(new Uint8Array([1, 2]));
  });

  it("配列と長いバイト列を読む", () => {
    // {"x5c": [h'00'*30]}
    const inner = new Uint8Array(30);
    const bytes = concat(
      new Uint8Array([0xa1, 0x63, 0x78, 0x35, 0x63, 0x81, 0x58, 30]),
      inner,
    );
    const value = decodeCbor(bytes) as { x5c: Uint8Array[] };
    expect(value.x5c).toHaveLength(1);
    expect(value.x5c[0]).toHaveLength(30);
  });

  it("途中で切れた入力は例外", () => {
    expect(() => decodeCbor(new Uint8Array([0x58, 10, 1, 2]))).toThrow();
  });
});

describe("authenticatorData", () => {
  it("カウンタと aaguid を読む", () => {
    const data = new Uint8Array(55 + 32);
    data.set(new TextEncoder().encode("appattestdevelop"), 37);
    new DataView(data.buffer).setUint32(33, 7);
    new DataView(data.buffer).setUint16(53, 32);

    const parsed = parseAuthenticatorData(data);
    expect(parsed.counter).toBe(7);
    expect(parsed.aaguid).toBe("appattestdevelop");
    expect(parsed.credentialId).toHaveLength(32);
  });

  it("assertion の固定長（37 バイト）も読める", () => {
    const data = new Uint8Array(37);
    new DataView(data.buffer).setUint32(33, 3);
    expect(parseAuthenticatorData(data).counter).toBe(3);
  });

  it("短すぎる入力は例外", () => {
    expect(() => parseAuthenticatorData(new Uint8Array(10))).toThrow();
  });
});

describe("署名と nonce の取り回し", () => {
  it("DER の署名を r‖s に直す", () => {
    const r = new Uint8Array(32).fill(0xaa);
    const s = new Uint8Array(32).fill(0xbb);
    const der = concat(
      new Uint8Array([0x30, 0x46, 0x02, 0x20]), r,
      new Uint8Array([0x02, 0x20]), s,
    );
    const raw = derToRawSignature(der);
    expect(raw).toHaveLength(64);
    expect(raw.slice(0, 32)).toEqual(r);
    expect(raw.slice(32)).toEqual(s);
  });

  it("先頭の 0x00 が付いた DER も 32 バイトに戻す", () => {
    const r = concat(new Uint8Array([0x00]), new Uint8Array(32).fill(0xff));
    const s = new Uint8Array(32).fill(0x11);
    const der = concat(
      new Uint8Array([0x30, 0x47, 0x02, 0x21]), r,
      new Uint8Array([0x02, 0x20]), s,
    );
    expect(derToRawSignature(der).slice(0, 32)).toEqual(new Uint8Array(32).fill(0xff));
  });

  it("証明書の拡張から nonce を取り出す", () => {
    const nonce = new Uint8Array(32).fill(0x5a);
    const extension = concat(new Uint8Array([0x30, 0x24, 0xa1, 0x22, 0x04, 0x20]), nonce);
    expect(extractNonce(extension)).toEqual(nonce);
  });

  it("形が違えば取り出さない", () => {
    expect(() => extractNonce(new Uint8Array(34))).toThrow();
  });
});

// ---------------------------------------------------------------- 無料枠

describe("無料枠（未契約者）", () => {
  it("無料で呼べるのは初回起動の体験だけ", () => {
    expect(freeLimit("onboarding_chat")).toBe(1);
    expect(freeLimit("onboarding_extract")).toBe(1);
  });

  it("対話・ジャーナル抽出・一括分類・振り返り・knowledge は無料で呼べない", () => {
    for (const feature of ["ai_chat", "journal_extract", "inbox_classify", "review", "knowledge", ""]) {
      expect(freeLimit(feature)).toBeUndefined();
    }
  });

  it("モデルと出力上限をこちらで決める（指定は無視する）", () => {
    const { body, maxTokens } = applyFreeLimits({
      model: "claude-opus-5",
      max_tokens: 8_000,
      messages: [],
    });
    expect(body.model).toBe("claude-haiku-4-5-20251001");
    expect(body.max_tokens).toBe(2_000);
    expect(maxTokens).toBe(2_000);
  });

  it("小さい max_tokens はそのまま尊重する", () => {
    expect(applyFreeLimits({ max_tokens: 500 }).maxTokens).toBe(500);
  });

  it("回数は機能ごとに数える", () => {
    let counts = emptyCounts("2026-09");
    counts = consumeCount(counts, "journal_extract");
    counts = consumeCount(counts, "journal_extract");
    expect(usedCount(counts, "journal_extract")).toBe(2);
    expect(usedCount(counts, "inbox_classify")).toBe(0);
  });

  it("月が変われば 0 から数え直す", () => {
    const lastMonth = consumeCount(emptyCounts("2026-08"), "journal_extract");
    expect(usedCount(countsFor(lastMonth, "2026-09"), "journal_extract")).toBe(0);
    expect(usedCount(countsFor(lastMonth, "2026-08"), "journal_extract")).toBe(1);
  });
});

describe("無料トライアル", () => {
  const day = 24 * 60 * 60 * 1000;
  const start = Date.parse("2026-10-01T09:00:00Z");

  it("始めていなければ無効", () => {
    expect(trialStatus(null, start).active).toBe(false);
  });

  it("7 日間だけ有効", () => {
    expect(trialStatus(start, start + 6 * day).active).toBe(true);
    expect(trialStatus(start, start + 7 * day - 1).active).toBe(true);
    expect(trialStatus(start, start + 7 * day).active).toBe(false);
    expect(trialStatus(start, start).endsAt).toBe(start + 7 * day);
  });

  it("合計の上限は日も月もまたいで効く（月が変わっても数え直さない）", () => {
    const limits = { daily: TRIAL.daily, monthly: TRIAL.total, total: TRIAL.total };
    const ledger = new Ledger(limits);
    const lastDayOfMonth = Date.parse("2026-09-30T12:00:00Z");
    const nextMonth = Date.parse("2026-10-01T12:00:00Z");

    // 9 月末までに、合計の上限まで残り 5,000 のところまで使った
    const usedSoFar = TRIAL.total - 5_000;
    const saved = {
      day: dayKey(lastDayOfMonth),
      month: monthKey(lastDayOfMonth),
      state: { dailyUsed: 15_000, monthlyUsed: usedSoFar, totalUsed: usedSoFar, holds: [] },
    };
    const restored = restore(saved, nextMonth);
    expect(restored.dailyUsed).toBe(0);
    expect(restored.monthlyUsed).toBe(0);
    expect(restored.totalUsed).toBe(usedSoFar);

    // 10 月 1 日: 日も月も 0 に戻っているが、合計の残りは 5,000 だけ
    expect(ledger.reserve(restored, 5_000, nextMonth, "a").ok).toBe(true);
    const over = ledger.reserve(restored, 5_001, nextMonth, "b");
    expect(over.ok).toBe(false);
    expect(over.reason).toBe("total");
  });

  it("精算で合計にも積む", () => {
    const ledger = new Ledger({ daily: TRIAL.daily, monthly: TRIAL.total, total: TRIAL.total });
    const now = Date.parse("2026-10-01T12:00:00Z");
    const reserved = ledger.reserve(emptyState(), 10_000, now, "h");
    expect(ledger.settle(reserved.state, "h", 3_000, now).totalUsed).toBe(3_000);
  });

  it("合計を渡さない台帳（Pro / Max）は合計で止めない", () => {
    const ledger = new Ledger({ daily: 100, monthly: 100 });
    const state = { ...emptyState(), totalUsed: 10_000_000 };
    expect(ledger.reserve(state, 50, Date.now(), "h").ok).toBe(true);
  });

  it("何を指定されても Haiku で呼ぶ", () => {
    expect(applyTrial({ model: "claude-opus-5" }).model).toBe("claude-haiku-4-5-20251001");
  });

  it("出力は 3,000 までに縛る（小さい指定はそのまま）", () => {
    expect(applyTrial({ max_tokens: 8_000 }).max_tokens).toBe(TRIAL.maxTokens);
    expect(applyTrial({}).max_tokens).toBe(TRIAL.maxTokens);
    expect(applyTrial({ max_tokens: 1_000 }).max_tokens).toBe(1_000);
  });

  it("1 回の押さえが 1 日の上限の 1/3 を超えない（1 日に何度も呼べる）", () => {
    // 入力 10 万バイト（約 3.3 万トークン）の大きめの会話でも
    expect(estimateReserve(100_000, TRIAL.maxTokens)).toBeLessThan(TRIAL.daily / 1.5);
    // ふつうの会話（入力 1.5 万バイト）なら 1 日の上限の 1/4 以下
    expect(estimateReserve(15_000, TRIAL.maxTokens)).toBeLessThanOrEqual(TRIAL.daily / 4);
  });

  it("1 日の上限は Pro と同じで、合計は 1 日の上限 × 7 日を超えない", () => {
    expect(TRIAL.daily).toBe(PLANS.pro.daily);
    expect(TRIAL.total).toBeLessThanOrEqual(TRIAL.daily * TRIAL.days);
    // 1 日あたりに均すと、少なくとも 1 日の上限の半分は使える
    expect(TRIAL.total / TRIAL.days).toBeGreaterThanOrEqual(TRIAL.daily / 2);
  });
});

describe("DeviceCheck のビット（入れ直し対策）", () => {
  it("トライアルの印は bit1 で、月が変わっても消えない", () => {
    expect(trialUsed({ bit0: false, bit1: true, lastUpdate: "2025-01" })).toBe(true);
    expect(trialUsed({ bit0: true, bit1: false, lastUpdate: "2026-10" })).toBe(false);
  });

  it("無料枠の印を付けても、トライアルの印は残す", () => {
    expect(bitsForFreeMark({ bit0: false, bit1: true, lastUpdate: "2026-09" }))
      .toEqual({ bit0: true, bit1: true });
  });

  it("トライアルの印を付けるとき、先月の無料枠の印は落とす（今月ぶんに化けさせない）", () => {
    expect(bitsForTrialMark({ bit0: true, bit1: false, lastUpdate: "2026-09" }, "2026-10"))
      .toEqual({ bit0: false, bit1: true });
    expect(bitsForTrialMark({ bit0: true, bit1: false, lastUpdate: "2026-10" }, "2026-10"))
      .toEqual({ bit0: true, bit1: true });
  });

  it("今月に開始した端末は使用済みと見なす", () => {
    expect(startedThisMonth({ bit0: true, bit1: false, lastUpdate: "2026-09" }, "2026-09"))
      .toBe(true);
  });

  it("先月のビットは古いので、今月は使える", () => {
    expect(startedThisMonth({ bit0: true, bit1: false, lastUpdate: "2026-08" }, "2026-09"))
      .toBe(false);
  });

  it("まだ一度も書いていない端末は使える", () => {
    expect(startedThisMonth({ bit0: false, bit1: false, lastUpdate: null }, "2026-09"))
      .toBe(false);
  });

  it("ビットが立っていなければ、月が同じでも使える", () => {
    expect(startedThisMonth({ bit0: false, bit1: false, lastUpdate: "2026-09" }, "2026-09"))
      .toBe(false);
  });
});

describe("base64url", () => {
  it("往復する", () => {
    const bytes = new Uint8Array([0, 1, 250, 251, 252, 253, 254, 255]);
    expect(fromBase64Url(toBase64Url(bytes))).toEqual(bytes);
  });
});

describe("Haiku での道具の強制", () => {
  const tool = { name: "record_journal", input_schema: { type: "object" } };

  it("道具が 1 つで auto なら、その道具を強制する", () => {
    const body = forceSingleTool({ tools: [tool], tool_choice: { type: "auto" } });
    expect(body.tool_choice).toEqual({ type: "tool", name: "record_journal" });
  });

  it("tool_choice が無くても強制する", () => {
    expect(forceSingleTool({ tools: [tool] }).tool_choice).toEqual({ type: "tool", name: "record_journal" });
  });

  it("道具が無い・複数・思考ありのときは触らない", () => {
    const chat = { messages: [] };
    expect(forceSingleTool(chat)).toBe(chat);
    const many = { tools: [tool, { ...tool, name: "other" }], tool_choice: { type: "auto" } };
    expect(forceSingleTool(many)).toBe(many);
    const thinking = { tools: [tool], thinking: { type: "enabled", budget_tokens: 1024 } };
    expect(forceSingleTool(thinking)).toBe(thinking);
  });
});

// ---------------------------------------------------------------- 攻撃への備え

describe("チャレンジ（保存せず署名で確かめる）", () => {
  const secret = "test-secret";
  const now = Date.parse("2026-09-29T09:00:00Z");

  it("発行したものは通る", async () => {
    const challenge = await makeChallenge(secret, now);
    expect(await checkChallenge(challenge, secret, now + 60_000)).toBe(true);
  });

  it("5 分を過ぎたら通さない", async () => {
    const challenge = await makeChallenge(secret, now);
    expect(await checkChallenge(challenge, secret, now + 5 * 60_000)).toBe(true);
    expect(await checkChallenge(challenge, secret, now + 5 * 60_000 + 1_000)).toBe(false);
  });

  it("未来の時刻は 30 秒のずれまで", async () => {
    const challenge = await makeChallenge(secret, now + 60_000);
    expect(await checkChallenge(challenge, secret, now)).toBe(false);
    expect(await checkChallenge(await makeChallenge(secret, now + 20_000), secret, now)).toBe(true);
  });

  it("別の鍵で作ったもの・書き換えたもの・形の違うものは通さない", async () => {
    const challenge = await makeChallenge(secret, now);
    expect(await checkChallenge(challenge, "other-secret", now)).toBe(false);

    const [issued, nonce, signature] = challenge.split(".");
    expect(await checkChallenge(`${issued}.AAAA${nonce}.${signature}`, secret, now)).toBe(false);
    expect(await checkChallenge(`${Number(issued) + 1}.${nonce}.${signature}`, secret, now)).toBe(false);
    expect(await checkChallenge("", secret, now)).toBe(false);
    expect(await checkChallenge("a.b", secret, now)).toBe(false);
    expect(await checkChallenge(`${issued}.${nonce}.!!!`, secret, now)).toBe(false);
  });

  it("セッションの JWT の署名をチャレンジとして使い回せない", async () => {
    const { token } = await issue({ sub: "u", kid: "k" }, secret, 60, now);
    expect(await checkChallenge(token, secret, now)).toBe(false);
  });

  it("毎回違う値になる", async () => {
    expect(await makeChallenge(secret, now)).not.toBe(await makeChallenge(secret, now));
  });
});

describe("回数の制限", () => {
  it("429 で、待てば戻ることを retry-after で伝える", async () => {
    const response = rateLimited();
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    const body = (await response.json()) as { error: { type: string } };
    // アプリは scope の無い 429 を「少し待ってもう一度」と出す（月・合計の上限と取り違えない）
    expect(body.error.type).toBe("rate_limited");
    expect((body.error as { scope?: string }).scope).toBeUndefined();
  });
});

describe("16 進", () => {
  it("バイト列を 2 桁ずつの 16 進にする", () => {
    expect(toHex(new Uint8Array([0, 15, 255]))).toBe("000fff");
  });
});
