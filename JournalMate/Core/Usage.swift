import Foundation

/// 課金（か 7 日間のトライアル）で解放される機能。
///
/// **トライアルが終わった後の無料プランでは、書くことも AI も使えない。**
/// 残るのは閲覧（カレンダー・ツリー・過去の記録）と Vault 書き出しだけ。
/// 自分のデータを見られなくなる・持ち出せなくなることはしない。
/// 無料枠を持つのは、プランを選ぶ前の初回起動の体験（`onboarding*`）だけ。
enum ProFeature: String, CaseIterable, Identifiable, Sendable {
    /// AI チャットの往復。原価が唯一青天井なのでここは無料枠を置かない。
    case aiChat = "ai_chat"
    /// 会話からのジャーナル抽出・PARA 自動推定。
    case journalExtract = "journal_extract"
    /// ジャーナルやノートを自分の手で書く・直す（Journal タブ、フォルダの「Add」「Edit」）。
    /// AI は呼ばないのでゲートウェイには出てこない。アプリの中だけの区分。
    case journalWrite = "journal_write"
    /// 過去のジャーナルを文脈にした対話。AI が過去の記録を踏まえて語りかけ、
    /// 「あの時どうしてたっけ」を過去から引き出す。教訓にまとめて渡すのではなく、その場で引く。
    /// 実体は `aiChat` の呼び出しに道具（`JournalRecall`）を渡すことなので、`X-Feature` は `ai_chat` のまま。
    /// ここにあるのは Paywall の一覧に並べるため。
    case pastRecall = "past_recall"
    /// 初回起動の「試しにジャーナリングしてみましょう」での対話。AI チャットと同じ中身だが、
    /// 体験のためだけに最初の 1 通ぶん（Haiku）の無料枠を置く。オンボーディングの外では使わない。
    case onboardingChat = "onboarding_chat"
    /// 初回起動の体験で、その会話を AI がジャーナルにする 1 回ぶんの無料枠。オンボーディングの外では使わない。
    case onboardingExtract = "onboarding_extract"
    /// フォルダの「自分の傾向」で、生データとジャーナルを調合して、傾向と向かうべき道を書き出す。
    /// ゲートウェイの無料枠（`FREE_FEATURES`）には入れない。
    case knowledge = "knowledge"

    var id: String { rawValue }

    /// 0 なら Pro 専用。1 以上なら無料ユーザーが月にその回数まで使える。
    var monthlyFreeLimit: Int {
        switch self {
        case .onboardingChat, .onboardingExtract: return 1
        case .aiChat, .journalExtract, .journalWrite, .pastRecall, .knowledge: return 0
        }
    }

    var title: String {
        switch self {
        case .aiChat, .onboardingChat: return String(localized: "Conversations with AI")
        case .journalExtract, .onboardingExtract: return String(localized: "Automatic journal extraction")
        case .journalWrite: return String(localized: "Writing journals")
        case .pastRecall: return String(localized: "Drawing on your past journals")
        case .knowledge: return String(localized: "Generating your patterns")
        }
    }

    var summary: String {
        switch self {
        case .aiChat, .onboardingChat:
            return String(localized: "Talk through what is on your mind, and it draws out what is worth writing down")
        case .journalExtract, .onboardingExtract:
            return String(localized: "Summarizes the conversation, infers the PARA category and layer, and decides where it goes")
        case .journalWrite:
            return String(localized: "Write and edit journals and notes in your own words. Past entries stay viewable and exportable without a plan")
        case .pastRecall:
            return String(localized: "The AI talks to you with your past journals in mind, and pulls up what you did back then when you ask “What did I do last time?”")
        case .knowledge:
            return String(localized: "Blends your raw data (life principles and direction) with your journals, and writes out your patterns and the path to head toward")
        }
    }

    var symbol: String {
        switch self {
        case .aiChat, .onboardingChat: return "bubble.left.and.text.bubble.right"
        case .journalExtract, .onboardingExtract: return "square.and.arrow.down"
        case .journalWrite: return "square.and.pencil"
        case .pastRecall: return "clock.arrow.circlepath"
        case .knowledge: return "sparkles"
        }
    }

    /// Paywall の機能一覧に並べるか。オンボーディング用の枠は買うものではないので出さない。
    var isListed: Bool { self != .onboardingChat && self != .onboardingExtract }
}

/// 機能を今この瞬間に使えるか。使えないときは Paywall を出す。
enum FeatureAccess: Equatable, Sendable {
    /// 契約済み。回数は数えない。
    case pro
    /// 無料枠で使える。`remaining` は今月の残り回数（この 1 回を含む）。
    case free(remaining: Int)
    /// 課金が必要。
    case locked

    var isAllowed: Bool {
        switch self {
        case .pro, .free: return true
        case .locked: return false
        }
    }

    /// 無料枠を消費する呼び出しか。契約者のぶんは数えない。
    var consumesFreeQuota: Bool {
        if case .free = self { return true }
        return false
    }
}

// MARK: - トークンの上限

/// 1 回の呼び出しで使ったトークン。Anthropic の応答の `usage` をそのまま読む。
/// 推測しない ＝ 課金元と同じ数字を数える。
struct TokenUsage: Equatable, Sendable {
    var input = 0
    var output = 0
    /// プロンプトキャッシュから読めたぶん。入力より桁違いに安いので別勘定にする。
    var cacheRead = 0

    /// 上限に数えるときの重み付き値。出力は入力よりずっと高いので、
    /// 素のトークン数で数えると「長文を書かせる人」だけが極端に得をする。
    var weighted: Int {
        input + output * TokenBudget.outputWeight + cacheRead / TokenBudget.cacheDiscount
    }

    var total: Int { input + output + cacheRead }

    var isEmpty: Bool { total == 0 }

    static func + (lhs: Self, rhs: Self) -> Self {
        TokenUsage(input: lhs.input + rhs.input,
                   output: lhs.output + rhs.output,
                   cacheRead: lhs.cacheRead + rhs.cacheRead)
    }
}

/// 1 日あたりの上限。**原価が青天井にならないための最後の砦**。
///
/// 無料枠（`ProFeature.monthlyFreeLimit`）が「何回使えるか」を決めるのに対し、
/// こちらは「どれだけ使えるか」を決める。回数だけでは、1 回の会話を無限に続ける人を
/// 止められないため両方が要る。
enum TokenBudget {

    /// 出力トークンの重み。原価が入力のおよそ 5 倍であることに合わせる。
    static let outputWeight = 5
    /// キャッシュ読み出しの割引率（入力の約 1/10 なので 10 で割る）。
    static let cacheDiscount = 10

    /// Pro の 1 日の上限（重み付きトークン）。Sonnet 5 で約 $0.16。
    /// 月の上限（サーバ側 `PLANS.pro.monthly` = 60 万）を数日で使い切らせないための値で、
    /// 7 日トライアルで解約されたときの持ち出しもここで決まる（最悪 56 万 ≈ $1.1）。
    static let daily = 80_000

    /// Max の 1 日の上限。Opus 5 で約 $0.8。月の上限（`PLANS.max.monthly` = 120 万）との比は Pro と同じ。
    static let maxDaily = 160_000

    /// 無料トライアルの 1 日の上限。Pro と同じ 8 万で、7 日間ふつうに使える量にしてある。
    /// モデルは Haiku なので約 $0.08。7 日の合計はサーバ側 `TRIAL.total`（40 万）で別に縛る。
    /// サーバ側 `TRIAL.daily` と同じ数字にしておく。
    static let trialDaily = 80_000

    /// プランごとの 1 日の上限。**サーバ側 `PLANS` と同じ数字**にしておく
    /// （食い違うと「アプリでは残っているのに 429」になる）。
    static func daily(for plan: PaidPlan) -> Int {
        switch plan {
        case .pro: return daily
        case .max: return maxDaily
        }
    }

    /// 残りがこれを下回ったら、新しい呼び出しを始めさせない。
    /// ストリーミングは走り出すと止まらないので、1 回ぶんの余白を残して手前で切る。
    static let headroom = 20_000
}

/// 有料プラン。どちらも全機能が使え、違いはモデルと使える量だけ。
/// Max は「月の上限に当たる人・もっと使いたい人」のための上位プラン。
enum PaidPlan: String, Sendable {
    /// Sonnet 5。月額 ¥770 / 年額 ¥7,700。
    case pro
    /// Opus 5・Pro の 2 倍の量。月額 ¥2,980 / 年額 ¥29,800。
    case max

    var title: String {
        switch self {
        case .pro: return "Pro"
        case .max: return "Max"
        }
    }

    /// App Store の価格が取れないとき（課金の未設定・読み込み失敗）に出す参考価格。
    /// 実際に請求される額は App Store の `localizedPriceString` が正で、取れればそちらを出す。
    func referencePrice(isAnnual: Bool) -> String {
        switch (self, isAnnual) {
        case (.pro, false): return "¥770"
        case (.pro, true): return "¥7,700"
        case (.max, false): return "¥2,980"
        case (.max, true): return "¥29,800"
        }
    }
}

/// 今日のぶんの消費状況。
struct DailyBudget: Equatable, Sendable {
    var used: Int
    var limit: Int

    var remaining: Int { max(0, limit - used) }
    var ratio: Double { limit > 0 ? min(1, Double(used) / Double(limit)) : 0 }
    /// 新しい呼び出しを始めてよいか。
    var canStart: Bool { remaining > TokenBudget.headroom }

    /// 上限に当たったときに画面へ出す説明。理由と、いつ戻るかと、いま何ができるかを言う。
    var exhaustedMessage: String {
        String(localized: """
            You have reached today's AI usage limit (\(used / 1_000)k / \(limit / 1_000)k). \
            It resets when the date changes. Until then, journaling, the calendar, and folders work as usual.
            """)
    }
}

enum Usage {

    /// 無料枠は暦月でリセットする。"2026-09"。
    static func period(for date: Date = Date()) -> String {
        periodFormatter.string(from: date)
    }

    /// 解放判定。純粋関数にしておき、`Verification` から直接確かめられるようにする。
    static func access(to feature: ProFeature, isPro: Bool, usedThisMonth: Int) -> FeatureAccess {
        if isPro { return .pro }
        let remaining = feature.monthlyFreeLimit - usedThisMonth
        return remaining > 0 ? .free(remaining: remaining) : .locked
    }

    private static let periodFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()
}
