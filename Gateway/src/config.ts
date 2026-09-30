/**
 * ゲートウェイの設定値。
 *
 * 上限まわりはアプリ側の `JournalMate/Core/Usage.swift` の `TokenBudget` と
 * **同じ数字**にしておく（アプリは表示と自制、こちらは強制。食い違うと
 * 「アプリでは残っているのに 429」になる）。
 */

export const ENTITLEMENT = "pro";
/** Max プランのエンタイトルメント。Max の商品は `pro` と `max` の**両方**に紐づける。 */
export const MAX_ENTITLEMENT = "max";

/** 重み付けの係数。原価比に合わせる。アプリ側 TokenBudget と一致させること。 */
export const OUTPUT_WEIGHT = 5;
export const CACHE_DISCOUNT = 10;

export type Plan = "pro" | "max";

export interface PlanSpec {
  /** このプランの呼び出しに使うモデル。アプリの指定に関わらずこちらで上書きする。 */
  model: string;
  /** 1 人 1 日の上限（重み付きトークン）。月の上限を数日で使い切らせないための値。 */
  daily: number;
  /** 1 人 1 か月の上限。採算を守るための値。 */
  monthly: number;
}

/**
 * プランごとのモデルと上限。月の上限は価格から逆算してある（$1 = ¥148、手数料 15%）。
 *
 * - Pro: 月額 ¥770 → 手取り ¥595 の 30% ≈ ¥178 を Sonnet 5（重み付き 1M あたり $2）に充てる
 * - Max: 月額 ¥2,980 → 手取り ¥2,303 の 40% ≈ ¥921 を Opus 5（同 $5）に充てる
 *
 * 日次・月次とも、アプリ側 `TokenBudget` と同じ数字にしておくこと。
 */
export const PLANS: Record<Plan, PlanSpec> = {
  pro: { model: "claude-sonnet-5", daily: 80_000, monthly: 600_000 },
  max: { model: "claude-opus-5", daily: 160_000, monthly: 1_200_000 },
};

/** 中継してよいモデル。ここに無いものは 400 で弾く。 */
export const ALLOWED_MODELS = new Set([
  "claude-opus-5",
  "claude-sonnet-5",
  "claude-haiku-4-5-20251001",
]);

/** そのまま Anthropic に渡してよい最上位キー。これ以外は落とす。 */
export const ALLOWED_KEYS = new Set([
  "model",
  "max_tokens",
  "stream",
  "system",
  "messages",
  "tools",
  "tool_choice",
  "output_config",
  "temperature",
  "stop_sequences",
]);

export const MAX_TOKENS_CAP = 8_000;
export const MAX_BODY_BYTES = 400_000;
export const MAX_MESSAGES = 200;

// ---------------------------------------------------------------- 無料枠
//
// 未契約者にも開ける機能と、その回数。アプリ側 `ProFeature.monthlyFreeLimit` と
// 同じ数字にしておく（アプリは表示と自制、こちらが強制）。
//
// **入れ直しで枠を戻させない**のが肝。App Attest の鍵も RevenueCat の匿名 ID も
// アプリを消せば作り直されるので、それだけでは塞げない。
// 端末に紐づく DeviceCheck のビット（アプリを削除しても Apple 側に残る）で
// 「この端末は今月の無料枠を開始した」を覚える（`devicecheck.ts`）。
// そのうえで 1 回あたりを安くし（FREE_MODEL）、全体の出費にも天井を置く（FREE_POOL_*）。

/**
 * 未契約でも呼べる機能。ここに無い機能は 402。
 *
 * **トライアルが終わった後の無料プランでは AI を使えない**（書くこと自体も有料。アプリ側で止める）。
 * ここに残すのは、プランを選ぶ前の初回起動の体験だけ。
 *
 * `onboarding_chat` は初回起動の「試しにジャーナリングしてみましょう」で、
 * 最初の 1 通にだけ AI が返事をするための枠。`onboarding_extract` はその会話を
 * ジャーナルにする 1 回。アプリはオンボーディング中にしかこれらのヘッダを送らない。
 * 月ごとに戻るが、Haiku・出力上限・共有プールが効くので、叩かれても額は小さい。
 */
export const FREE_FEATURES = new Map<string, number>([
  ["onboarding_chat", 1],
  ["onboarding_extract", 1],
]);

/**
 * DeviceCheck のビットを見ない（立てもしない）無料機能。
 *
 * ビットは端末に 1 本しかなく「今月の無料枠を開始した」を機能をまたいで覚える。
 * オンボーディングの 1 通までこれに乗せると、先に抽出を使った端末では体験の返事が
 * `device_used` で返らず、逆にこの 1 通がその後の抽出を塞ぐ。1 回きりの Haiku なので、
 * 端末 ID ごとの台帳と共有プールだけで守れば足りる。
 */
export const DEVICE_UNBOUND_FREE_FEATURES = new Set(["onboarding_chat", "onboarding_extract"]);

/** 無料の呼び出しはモデルを固定する（アプリが何を指定してきても上書きする）。 */
export const FREE_MODEL = "claude-haiku-4-5-20251001";
/** 無料の呼び出しの出力上限。 */
export const FREE_MAX_TOKENS = 2_000;

/**
 * アプリ内の無料トライアル。App Store を通さない独立したプランで、自動課金はしない。
 * **1 端末 1 回**（DeviceCheck の bit1 で覚える。入れ直してもやり直せない）。
 *
 * 期間中は全機能を開けるが、モデルは Haiku に固定する。
 * 1 日の上限は Pro と同じ 8 万（チャット 15〜20 往復ほど）にして、7 日間ふつうに使えるようにする。
 * 合計は 1 日 8 万 × 7 日の 56 万より少し低い 40 万に抑える（毎日上限まで使う人は稀）。
 * Haiku は重み付き 100 万あたり約 $1 なので、1 人あたり最悪でも約 $0.40。
 * 終わった後は無料プラン（閲覧と書き出しだけ）になるので、ここが課金前に AI を試せる唯一の枠。
 */
export const TRIAL = {
  model: FREE_MODEL,
  days: 7,
  daily: 80_000,
  total: 400_000,
  /**
   * 1 回の出力上限。アプリは Sonnet / Opus の思考ぶんを見込んで 8,000 を送ってくるが、
   * 思考しない Haiku には多すぎる。呼ぶ前に max_tokens × 5 を押さえるので、8,000 のままだと
   * 1 回で 4 万を押さえ、1 日 8 万の半分を使った時点で次が 429 になる。
   * 3,000 なら返答（3〜5 文）もジャーナル化・傾向の生成も収まり、1 回の押さえは約 1.5 万＋入力。
   */
  maxTokens: 3_000,
};

/**
 * 無料枠**全体**の 1 日・1 か月の上限（重み付きトークン）。最後の砦。
 * 無料の呼び出しは初回起動の体験（1 人 2 回）だけなので、1 日 200 万（Haiku で約 $2）で足りる。
 * 1 回の押さえは最大で約 2.3 万（入力の見積もり＋出力 2,000 × 5）なので、1 日 80 人ほどが体験できる。
 * 足りなくなったら上げる。月は 3,000 万（約 $30）。
 */
export const FREE_POOL_DAILY = 2_000_000;
export const FREE_POOL_MONTHLY = 30_000_000;

// ---------------------------------------------------------------- 回数の制限
//
// トークンの上限は「どれだけ使えるか」を縛るが、「どれだけ速く叩けるか」は縛らない。
// 小さな呼び出しの連打で Worker の 1 日の枠（無料プランで 10 万リクエスト）を食い潰されないよう、
// 回数でも縛る。Cloudflare の Rate Limiting バインディング（wrangler.toml）を使う。
// 数えるのはデータセンターごとの概数なので、境目は厳密ではない（守りとしてはそれで足りる）。
//
//   IP_LIMITER   … 認証前（/v1/challenge・/v1/session）。IP ごとに 1 分 60 回
//   USER_LIMITER … 認証後（/v1/messages・/v1/trial/start）。端末 ID ごとに 1 分 30 回
//
// 回数そのものは wrangler.toml に書く（バインディングの設定でしか決められない）。
/** 共有プールの Durable Object の名前。 */
export const FREE_POOL_ID = "free-pool";

export const SESSION_TTL_SECONDS = 24 * 60 * 60;
export const CHALLENGE_TTL_SECONDS = 5 * 60;
/**
 * 購読状態のキャッシュ。変化は Webhook で即時に届くので長めでよい。
 * 無料プランの KV は書き込みが 1 日 1,000 回まで（cloudflare.md §9）なので、書き直しを減らす。
 */
export const SUBSCRIPTION_CACHE_SECONDS = 60 * 60;
/**
 * アプリの申告とキャッシュが食い違ったとき、聞き直してよい最短の間隔。
 * 購入直後に「未契約」のキャッシュが 1 時間残るのを防ぎつつ、申告で毎回聞き直させない。
 */
export const SUBSCRIPTION_RECHECK_SECONDS = 60;
/** 精算されずに残った仮押さえを捨てるまでの時間。 */
export const HOLD_TTL_MS = 5 * 60 * 1000;

export const ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages";
export const ANTHROPIC_VERSION = "2023-06-01";

export interface Env {
  /** 1 ユーザー 1 個の台帳（Durable Object）。 */
  BUDGET: DurableObjectNamespace;
  /** チャレンジ・端末鍵・購読状態のキャッシュ。 */
  CACHE: KVNamespace;

  /** 秘密（wrangler secret put で入れる）。 */
  ANTHROPIC_API_KEY: string;
  /**
   * キーがワークスペースに属していないときだけ入れる（`anthropic-workspace-id` として送る）。
   * ワークスペースのキーなら不要。
   */
  ANTHROPIC_WORKSPACE_ID?: string;
  /** RevenueCat の **secret** キー。公開 SDK キーとは別物。 */
  RC_SECRET_KEY: string;
  /** RevenueCat の Webhook に設定する Authorization ヘッダの値。 */
  RC_WEBHOOK_SECRET: string;
  /** セッション JWT の署名鍵。 */
  SESSION_SECRET: string;

  /** Apple App Attest のルート CA（PEM）。Apple から落としたものを入れる。 */
  APPLE_ROOT_CA_PEM: string;
  /** "<TeamID>.<BundleID>"。例: "ABCDE12345.app.journalmate" */
  APP_ID: string;

  /**
   * DeviceCheck（無料枠を端末に縛るために使う）。
   * App Store Connect で作った鍵（.p8 の中身）と、その Key ID、Team ID。
   * 揃っていないときは端末の見分けができないので、無料枠は共有プールの天井だけが効く。
   */
  DEVICECHECK_KEY_P8?: string;
  DEVICECHECK_KEY_ID?: string;
  APPLE_TEAM_ID?: string;
  DEVICECHECK_ENV?: "production" | "development";

  /**
   * App Attest の扱い。
   * - "on":   検証する（本番）
   * - "off":  検証しない。シミュレータ開発用。DEV_BYPASS_TOKEN が必須になる
   */
  ATTEST_MODE: "on" | "off";
  DEV_BYPASS_TOKEN?: string;

  /** 回数の制限。無い環境（テスト・wrangler dev）では制限しない。 */
  IP_LIMITER?: RateLimit;
  USER_LIMITER?: RateLimit;
}
