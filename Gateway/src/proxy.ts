/**
 * Anthropic への中継と、そこで使われたトークンの計量。
 *
 * **素通しにはしない。** エンドポイントが 1 回漏れたら、誰でも使える無料の
 * Claude プロキシになってしまう。モデル・上限・本文の大きさをここで縛る。
 */

import {
  ALLOWED_KEYS,
  ALLOWED_MODELS,
  ANTHROPIC_ENDPOINT,
  ANTHROPIC_VERSION,
  CACHE_DISCOUNT,
  MAX_BODY_BYTES,
  MAX_MESSAGES,
  MAX_TOKENS_CAP,
  OUTPUT_WEIGHT,
  PLANS,
  Plan,
} from "./config";

export interface TokenUsage {
  input: number;
  output: number;
  cacheRead: number;
}

export const zeroUsage: TokenUsage = { input: 0, output: 0, cacheRead: 0 };

/** 重み付け。アプリ側 `TokenUsage.weighted` と同じ式にしておくこと。 */
export function weigh(usage: TokenUsage): number {
  return (
    usage.input +
    usage.output * OUTPUT_WEIGHT +
    Math.floor(usage.cacheRead / CACHE_DISCOUNT)
  );
}

export function readUsage(value: unknown): TokenUsage {
  if (!value || typeof value !== "object") return { ...zeroUsage };
  const fields = value as Record<string, unknown>;
  const num = (key: string) => (typeof fields[key] === "number" ? (fields[key] as number) : 0);
  return {
    input: num("input_tokens"),
    output: num("output_tokens"),
    cacheRead: num("cache_read_input_tokens"),
  };
}

export function addUsage(a: TokenUsage, b: TokenUsage): TokenUsage {
  return {
    input: a.input + b.input,
    output: a.output + b.output,
    cacheRead: a.cacheRead + b.cacheRead,
  };
}

export type SanitizeResult =
  | { ok: true; body: Record<string, unknown>; stream: boolean; maxTokens: number }
  | { ok: false; reason: string };

/**
 * 受け取った body を検査して、渡してよい形だけを作り直す。
 * 知らないキーは通さない（新しいパラメータが増えたらここを直す）。
 */
export function sanitize(raw: unknown, byteLength: number): SanitizeResult {
  if (byteLength > MAX_BODY_BYTES) {
    return { ok: false, reason: "本文が大きすぎます" };
  }
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return { ok: false, reason: "本文が JSON オブジェクトではありません" };
  }

  const input = raw as Record<string, unknown>;

  const model = input.model;
  if (typeof model !== "string" || !ALLOWED_MODELS.has(model)) {
    return { ok: false, reason: "許可されていないモデルです" };
  }

  const messages = input.messages;
  if (!Array.isArray(messages) || messages.length === 0) {
    return { ok: false, reason: "messages がありません" };
  }
  if (messages.length > MAX_MESSAGES) {
    return { ok: false, reason: "messages が多すぎます" };
  }

  const requested = typeof input.max_tokens === "number" ? input.max_tokens : MAX_TOKENS_CAP;
  const maxTokens = Math.min(Math.max(1, Math.floor(requested)), MAX_TOKENS_CAP);
  const stream = input.stream === true;

  const body: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(input)) {
    if (ALLOWED_KEYS.has(key)) body[key] = value;
  }
  body.max_tokens = maxTokens;

  return { ok: true, body, stream, maxTokens };
}

/**
 * 契約者の呼び出しは、プランのモデルに差し替える。
 * アプリが何を指定してきても、Pro が Opus を呼ぶことはできない（原価が合わない）。
 */
export function applyPlan(body: Record<string, unknown>, plan: Plan): Record<string, unknown> {
  return { ...body, model: PLANS[plan].model };
}

/**
 * 道具が 1 つだけの呼び出し（構造化出力）で、その道具を必ず呼ばせる。
 *
 * アプリは `tool_choice: auto` とプロンプトの指示で呼ばせている（Sonnet 5 / Opus 5 は
 * 既定で思考が走り、強制指定と併用できないため）。ところが無料枠・トライアルで Haiku に
 * 差し替えると、Haiku は指示を無視して地の文で答えることがあり、アプリは
 * 「構造化された結果を取り出せませんでした」になる。Haiku は思考なしで動くので強制できる。
 * **Haiku に差し替えた body にだけ**使う。
 */
export function forceSingleTool(body: Record<string, unknown>): Record<string, unknown> {
  const tools = body.tools;
  if (!Array.isArray(tools) || tools.length !== 1 || body.thinking !== undefined) return body;
  const name = (tools[0] as { name?: unknown } | null)?.name;
  if (typeof name !== "string") return body;
  const choice = body.tool_choice as { type?: unknown } | undefined;
  if (choice && choice.type !== "auto") return body;
  return { ...body, tool_choice: { type: "tool", name } };
}

/**
 * 始める前に押さえる量。入力は本文の長さから粗く見積もる。
 *
 * 正確である必要はない。**実際より小さく見積もらない**ことだけが要件で、
 * 終わったら実測で精算するので多めに押さえておけば安全側に倒れる。
 */
export function estimateReserve(byteLength: number, maxTokens: number): number {
  const inputEstimate = Math.ceil(byteLength / 3);
  return inputEstimate + maxTokens * OUTPUT_WEIGHT;
}

/**
 * SSE を素通ししながら usage を拾う。
 *
 * バッファせずに流すのが肝（バッファすると、アプリ側の「1 文字ずつ出る」体験が消える）。
 * 入力側は `message_start`、出力側は `message_delta` で確定する。
 */
export function meterStream(
  upstream: ReadableStream<Uint8Array>,
  onDone: (usage: TokenUsage) => void,
): ReadableStream<Uint8Array> {
  let usage: TokenUsage = { ...zeroUsage };
  let pending = "";
  let reported = false;

  const report = () => {
    if (reported) return;
    reported = true;
    onDone(usage);
  };

  const consume = (chunk: string) => {
    pending += chunk;
    const lines = pending.split("\n");
    pending = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.startsWith("data: ")) continue;
      try {
        const event = JSON.parse(line.slice(6)) as Record<string, unknown>;
        if (event.type === "message_start") {
          const message = event.message as Record<string, unknown> | undefined;
          usage = addUsage(usage, readUsage(message?.usage));
        } else if (event.type === "message_delta") {
          usage = addUsage(usage, readUsage(event.usage));
        }
      } catch {
        // 壊れた行は無視する。中継そのものは止めない。
      }
    }
  };

  const decoder = new TextDecoder();
  return upstream.pipeThrough(
    new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        controller.enqueue(chunk);
        consume(decoder.decode(chunk, { stream: true }));
      },
      flush() {
        report();
      },
      // 途中で切れても、そこまでに生成されたぶんは課金されている。必ず報告する。
      cancel() {
        report();
      },
    }),
  );
}

/**
 * `workspaceId` は、ワークスペースに属さない API キー（組織の管理用キーなど）を使うときだけ要る。
 * その場合 Anthropic は `anthropic-workspace-id` ヘッダが無いと 400 を返す。
 */
export async function callAnthropic(
  body: Record<string, unknown>,
  apiKey: string,
  workspaceId?: string,
): Promise<Response> {
  const headers: Record<string, string> = {
    "content-type": "application/json",
    "x-api-key": apiKey,
    "anthropic-version": ANTHROPIC_VERSION,
  };
  if (workspaceId) headers["anthropic-workspace-id"] = workspaceId;
  return await fetch(ANTHROPIC_ENDPOINT, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}
