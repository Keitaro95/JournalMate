/**
 * 応答の小物。
 *
 * ステータスコードはアプリ側の `ClaudeClient.Failure` がそのまま文言にする。
 *   401 … 認証（セッションが無い・切れた）
 *   402 … 未契約
 *   429 … 上限（レート・トークン）
 */

export function json(value: unknown, status = 200, headers: HeadersInit = {}): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

export function badRequest(reason: string): Response {
  return json({ error: { type: "invalid_request", message: reason } }, 400);
}

export function unauthorized(reason: string): Response {
  return json({ error: { type: "unauthorized", message: reason } }, 401);
}

export function paymentRequired(
  message = "Pro の契約が必要です",
  scope?: "free_exhausted" | "device_used",
): Response {
  return json({ error: { type: "subscription_required", scope, message } }, 402);
}

/** 回数の制限（短時間の連打）。待てば戻るので retry-after を付ける。 */
export function rateLimited(retryAfterSeconds = 60): Response {
  return json(
    { error: { type: "rate_limited", message: "リクエストが多すぎます。少し待ってからお試しください" } },
    429,
    { "retry-after": String(retryAfterSeconds) },
  );
}

const LIMIT_MESSAGES = {
  daily: "今日の利用上限に達しました",
  monthly: "今月の利用上限に達しました",
  total: "無料トライアルの利用上限に達しました",
} as const;

export function tooMany(reason: keyof typeof LIMIT_MESSAGES, resetAt: number): Response {
  return json(
    { error: { type: "budget_exhausted", scope: reason, message: LIMIT_MESSAGES[reason] } },
    429,
    // 合計の上限は日付では戻らないので、待てば直るとは言わない。
    reason === "total"
      ? {}
      : { "retry-after": String(Math.max(1, resetAt - Math.floor(Date.now() / 1000))) },
  );
}
