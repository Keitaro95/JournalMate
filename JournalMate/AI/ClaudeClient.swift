import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "JournalMate", category: "ClaudeClient")

/// Claude Messages API の薄いクライアント。
/// Swift には公式 SDK がないので `POST /v1/messages` を直接叩く。
///
/// 宛先は 2 通りある。ユーザー自身のキーがあるときは Anthropic を直接、
/// サブスクリプション契約者のときは自前のゲートウェイを経由する。
/// **Anthropic のキーをアプリに埋め込んではいけない**ので、
/// 契約者ぶんの原価を自分で持つには中継する側が要る（`BillingConfig` 参照）。
struct ClaudeClient: Sendable {

    let endpoint: URL
    let headers: [String: String]

    /// 1 回の呼び出しが終わるたびに、応答が申告したトークン数を渡す。
    /// 呼び出し側（`Store`）が日ごとに積んで上限の判断に使う。
    var onUsage: (@Sendable (TokenUsage) -> Void)?

    /// Pro のモデル。
    static let model = "claude-sonnet-5"
    /// Max のモデル。ゲートウェイもプランを見て同じものに差し替えるので、ここは表示と整合のため。
    static let maxModel = "claude-opus-5"
    /// 無料トライアルのモデル。これもゲートウェイが上書きする。
    static let trialModel = "claude-haiku-4-5-20251001"

    static func model(for plan: PaidPlan) -> String {
        switch plan {
        case .pro: return model
        case .max: return maxModel
        }
    }

    /// この呼び出しで使うモデル。既定は Pro と同じ。Max の契約者は `Entitlement` が差し替える。
    var model = ClaudeClient.model

    /// アプリ（RevenueCat SDK）が知っている、いま契約しているプラン。ゲートウェイに `X-Plan` で伝える。
    /// サーバはこれを信用せず、キャッシュと食い違ったときに RevenueCat へ聞き直すきっかけにだけ使う
    /// （購入直後に「未契約」のキャッシュが残っていても、すぐ契約者として扱われる）。
    var claimedPlan: PaidPlan?
    private static let anthropicEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    /// API キーで Anthropic に直接つなぐ。アプリからは使わず、検証用にだけ残す。
    init(apiKey: String) {
        endpoint = Self.anthropicEndpoint
        headers = [
            "x-api-key": apiKey,
            "anthropic-version": Self.apiVersion,
        ]
    }

    /// ゲートウェイ経由。同じ body をそのまま中継する前提。
    ///
    /// 認証は `authorize` が返すセッショントークン（App Attest で発行されたもの）。
    /// appUserID をヘッダに載せるだけでは認証にならない（文字列なので詐称できる）。
    ///
    /// - `feature`: どの機能の呼び出しか。サーバは未契約者にこれを見て
    ///   無料枠のある機能だけを通す。
    /// - `deviceToken`: DeviceCheck の端末トークン。無料枠を端末に縛るために使う
    ///   （入れ直して枠を作り直させない）。契約者には要らない。
    init(gateway: URL,
         feature: ProFeature?,
         authorize: @escaping @Sendable (_ rejected: String?) async throws -> String,
         deviceToken: (@Sendable () async -> String?)? = nil) {
        endpoint = gateway
        headers = ["anthropic-version": Self.apiVersion]
        self.feature = feature
        self.authorize = authorize
        self.deviceToken = deviceToken
    }

    /// ゲートウェイ用の認可ヘッダを作る処理。BYO キーのときは nil。
    private var authorize: (@Sendable (_ rejected: String?) async throws -> String)?
    private var deviceToken: (@Sendable () async -> String?)?
    private var feature: ProFeature?

    /// サーバが返してきた無料枠の残り。アプリの数え（`feature_usage`）を
    /// これで上書きすると、入れ直して 0 に戻った表示がサーバの数字に揃う。
    var onFreeQuota: (@Sendable (ProFeature, Int) -> Void)?

    /// 会話の 1 往復分。
    struct Turn: Sendable {
        var role: String   // "user" | "assistant"
        var text: String
    }

    /// 構造化された結果を受け取るための道具立て。
    /// `strict` を付けて input が必ずスキーマに合うようにする。
    ///
    /// スキーマは `[String: Any]` ではなく JSON 文字列で持つ。
    /// `[String: Any]` は Sendable ではなく、並行境界を越えられないため。
    struct Tool: Sendable {
        var name: String
        var description: String
        /// `{"type":"object", "properties": {...}, "required": [...], "additionalProperties": false}`
        var schemaJSON: String

        func payload() throws -> [String: Any] {
            guard let schema = try JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))
                    as? [String: Any] else {
                throw Failure.malformedResponse
            }
            return [
                "name": name,
                "description": description,
                "strict": true,
                "input_schema": schema,
            ]
        }
    }

    enum Failure: Swift.Error, LocalizedError {
        /// 402。契約か無料枠が要る。画面は Paywall を出す。
        case needsPro(String)
        /// 429。ゲートウェイの月の上限に当たった。日次と違い、待っても今月は戻らない。
        /// `offersMax` が true なら Max を案内する（Max の人に「Max なら 2 倍」とは言わない）。
        case monthlyLimitReached(offersMax: Bool)
        /// 429。無料トライアルの 7 日間の合計に当たった。期間が残っていても戻らない。
        case trialLimitReached
        case http(status: Int, body: String)
        case refused(String)
        case noToolCall
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .needsPro(let message):
                return message
            case .trialLimitReached:
                return String(localized: """
                    You have used up the AI allowance for your free trial. \
                    Journaling, the calendar, and folders work as usual. To keep using AI, choose Pro or Max.
                    """)
            case .monthlyLimitReached(let offersMax):
                return offersMax
                    ? String(localized: """
                        You have reached this month's AI usage limit. It resets at the start of next month (UTC). \
                        Journaling, the calendar, and folders work as usual. The Max plan offers twice the usage.
                        """)
                    : String(localized: """
                        You have reached this month's AI usage limit. It resets at the start of next month (UTC). \
                        Journaling, the calendar, and folders work as usual.
                        """)
            case .http(let status, _):
                if status == 429 { return String(localized: "Rate limit reached. Wait a moment and try again (429)") }
                // 本文（JSON）は見せない。中身は `failure(status:body:)` でログにだけ残す。
                return String(localized: "We couldn't connect to AI right now. Please wait a moment and try again.")
            case .refused(let explanation):
                return String(localized: "Claude declined to respond to this content. \(explanation)")
            case .noToolCall:
                return String(localized: "Could not extract a structured result")
            case .malformedResponse:
                return String(localized: "Could not interpret the response")
            }
        }
    }

    // MARK: - ストリーミング（チャット画面用）

    /// テキストを逐次返す。長い応答でもタイムアウトしないし、UI に流し込める。
    func streamText(system: String, turns: [Turn], maxTokens: Int = 8_000) -> AsyncThrowingStream<String, Swift.Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body: [String: Any] = [
                        "model": model,
                        "max_tokens": maxTokens,
                        "stream": true,
                        "system": system + Self.languageInstruction,
                        "messages": turns.map { ["role": $0.role, "content": $0.text] },
                    ]
                    _ = try await streamMessage(body) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 道具を使いながら返答を流すときに、画面へ渡すもの。
    enum ReplyEvent: Sendable {
        /// 返答の本文の続き。
        case text(String)
        /// AI が道具を呼んだ。画面は「過去の記録を探しています」を出す。
        case toolUse(name: String, input: Data)
    }

    /// 道具を実行する側。結果の文と、失敗だったかを返す。
    typealias ToolRunner = @Sendable (_ name: String, _ input: Data) async -> (text: String, isError: Bool)

    /// 道具を渡して返答を流す。AI が道具を呼んだらこちらで実行して結果を返し、
    /// AI が答え終わるまで往復する（手動のツールループ）。
    ///
    /// - `maxRounds`: 道具を呼べる往復の上限。超えたら道具を閉じて（`tool_choice: none`）答えさせる。
    /// - `shouldContinue`: 往復のたびに聞く。1 日の上限に近づいたら false を返して打ち切る。
    /// - `briefing`: 最後のユーザーの発言の後ろに、別のテキストブロックとして添える（検索意図など）。
    ///   システムプロンプトに混ぜないのは、そこを毎回変えるとキャッシュが効かなくなるため。
    ///
    /// 道具の結果は返り値に残さない。会話ログに保存されるのは本文だけなので、
    /// 次の発言では読んだ記録の全文を持ち回らない（必要ならまた探す）。
    func streamReply(system: String, turns: [Turn], tools: [Tool], maxRounds: Int,
                     maxTokens: Int = 8_000,
                     briefing: String? = nil,
                     runTool: @escaping ToolRunner,
                     shouldContinue: @escaping @Sendable () async -> Bool = { true })
        -> AsyncThrowingStream<ReplyEvent, Swift.Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let toolPayloads = try tools.map { try $0.payload() }
                    var messages = Self.messages(turns, briefing: briefing)
                    var hasText = false
                    var needsBreak = false

                    for round in 0...maxRounds {
                        var body: [String: Any] = [
                            "model": model,
                            "max_tokens": maxTokens,
                            "stream": true,
                            // 道具とシステムプロンプトは往復のあいだ変わらないので、キャッシュに載せる。
                            "system": [[
                                "type": "text",
                                "text": system + Self.languageInstruction,
                                "cache_control": ["type": "ephemeral"],
                            ]],
                            "messages": Self.markingCacheBreakpoint(messages),
                            "tools": toolPayloads,
                        ]
                        if round == maxRounds { body["tool_choice"] = ["type": "none"] }

                        let reply = try await streamMessage(body) { text in
                            // 道具を挟んだ前後の文がくっつかないように、段落を分ける。
                            if needsBreak { continuation.yield(.text("\n\n")); needsBreak = false }
                            hasText = true
                            continuation.yield(.text(text))
                        }

                        let calls = reply.content.filter { $0["type"] as? String == "tool_use" }
                        guard reply.stopReason == "tool_use", !calls.isEmpty, round < maxRounds else { break }

                        // 思考ブロックも含め、応答の content はそのまま返す（書き換えると続きが読めない）。
                        messages.append(["role": "assistant", "content": reply.content])
                        var results: [[String: Any]] = []
                        for call in calls {
                            let name = call["name"] as? String ?? ""
                            let input = try JSONSerialization.data(withJSONObject: call["input"] ?? [String: Any]())
                            continuation.yield(.toolUse(name: name, input: input))
                            let output = await runTool(name, input)
                            results.append([
                                "type": "tool_result",
                                "tool_use_id": call["id"] as? String ?? "",
                                "content": output.text,
                                "is_error": output.isError,
                            ])
                        }
                        // 並列に呼ばれた道具の結果は、1 つの user ターンにまとめて返す。
                        messages.append(["role": "user", "content": results])
                        needsBreak = hasText

                        guard await shouldContinue() else { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 会話を messages にする。`briefing` があれば最後のユーザーの発言に別ブロックで添える。
    static func messages(_ turns: [Turn], briefing: String?) -> [[String: Any]] {
        var messages: [[String: Any]] = turns.map { ["role": $0.role, "content": $0.text] }
        if let briefing, !briefing.isEmpty, let last = turns.last, last.role == "user" {
            messages[messages.count - 1]["content"] = [
                ["type": "text", "text": last.text],
                ["type": "text", "text": briefing],
            ]
        }
        return messages
    }

    /// 最後のメッセージの最後のブロックにキャッシュの区切りを置く。
    /// 往復のたびに前回までの会話を読み直すので、そこをキャッシュから読ませる。
    static func markingCacheBreakpoint(_ messages: [[String: Any]]) -> [[String: Any]] {
        guard var last = messages.last else { return messages }
        var blocks: [[String: Any]]
        if let text = last["content"] as? String {
            blocks = [["type": "text", "text": text]]
        } else if let content = last["content"] as? [[String: Any]], !content.isEmpty {
            blocks = content
        } else {
            return messages
        }
        blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"]
        last["content"] = blocks
        return messages.dropLast() + [last]
    }

    /// ストリーミングで受け取った 1 回ぶんの応答。
    private struct StreamedMessage {
        /// 応答の content ブロック。道具の往復では、これをそのまま assistant ターンとして送り返す。
        var content: [[String: Any]]
        var stopReason: String?
    }

    /// 1 回ぶんの SSE を読み切る。本文は `onText` に流しつつ、content ブロックを組み立て直して返す。
    private func streamMessage(_ body: [String: Any],
                               onText: (String) -> Void) async throws -> StreamedMessage {
        // 失敗しても、そこまでに生成されたぶんは課金されている。
        // 途中終了でも必ず報告するために defer で出す。
        var usage = TokenUsage()
        defer { onUsage?(usage) }

        let (bytes, response) = try await send(body) { try await URLSession.shared.bytes(for: $0) }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var message = ""
            for try await line in bytes.lines { message += line }
            throw Self.failure(status: http.statusCode, body: Data(message.utf8), model: model)
        } else if let http = response as? HTTPURLResponse {
            reportFreeQuota(http)
        }

        var blocks: [Int: [String: Any]] = [:]
        var partialJSON: [Int: String] = [:]
        var stopReason: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let json = String(line.dropFirst(6))
            guard let event = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                    as? [String: Any] else { continue }
            let index = event["index"] as? Int ?? 0

            switch event["type"] as? String {
            case "message_start":
                // 入力側のトークンは最初のイベントで確定する。
                if let message = event["message"] as? [String: Any] {
                    usage = usage + Self.usage(from: message["usage"])
                }
            case "content_block_start":
                blocks[index] = event["content_block"] as? [String: Any] ?? [:]
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any] else { continue }
                switch delta["type"] as? String {
                case "text_delta":
                    let text = delta["text"] as? String ?? ""
                    let sofar = blocks[index]?["text"] as? String ?? ""
                    blocks[index, default: ["type": "text"]]["text"] = sofar + text
                    onText(text)
                case "thinking_delta":
                    let thinking = blocks[index]?["thinking"] as? String ?? ""
                    blocks[index]?["thinking"] = thinking + (delta["thinking"] as? String ?? "")
                case "signature_delta":
                    let signature = blocks[index]?["signature"] as? String ?? ""
                    blocks[index]?["signature"] = signature + (delta["signature"] as? String ?? "")
                case "input_json_delta":
                    partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                default:
                    break
                }
            case "content_block_stop":
                // 道具の入力は断片で届くので、ブロックが閉じたところでまとめて読む。空なら引数なし。
                if blocks[index]?["type"] as? String == "tool_use" {
                    let raw = partialJSON[index] ?? ""
                    blocks[index]?["input"] = raw.isEmpty
                        ? [String: Any]()
                        : (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) ?? [String: Any]()
                }
            case "message_delta":
                // 出力側は最後にまとめて申告される。
                usage = usage + Self.usage(from: event["usage"])
                if let delta = event["delta"] as? [String: Any] {
                    stopReason = delta["stop_reason"] as? String ?? stopReason
                    // Opus 5 は安全性判断で応答を断ることがある（HTTP は 200 のまま）。
                    if stopReason == "refusal" {
                        let details = delta["stop_details"] as? [String: Any]
                        throw Failure.refused(details?["explanation"] as? String ?? "")
                    }
                }
            default:
                break
            }
        }

        let content = blocks.keys.sorted().compactMap { blocks[$0] }
        return StreamedMessage(content: content, stopReason: stopReason)
    }

    // MARK: - 構造化出力（ジャーナル抽出・ツリー生成用）

    /// 道具を 1 つだけ渡し、その入力を構造化データとして受け取る。
    /// `tool_choice` は auto のまま、システムプロンプトで必ず呼ぶよう指示する
    /// （強制指定は拡張思考と併用できないモデルがあるため避ける）。
    /// 戻り値は tool_use ブロックの input を再シリアライズした JSON。
    /// 呼び出し側は `Codable` でデコードする。
    func callTool(system: String, turns: [Turn], tool: Tool,
                  maxTokens: Int = 4_000) async throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system + Self.languageInstruction
                + "\n\n必ず `\(tool.name)` ツールを呼び出して答えること。地の文だけで答えてはいけない。",
            "tools": [try tool.payload()],
            "tool_choice": ["type": "auto"],
            "messages": turns.map { ["role": $0.role, "content": $0.text] },
        ]

        let (data, response) = try await send(body) { try await URLSession.shared.data(for: $0) }
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        guard http.statusCode == 200 else {
            throw Self.failure(status: http.statusCode, body: data, model: model)
        }
        reportFreeQuota(http)

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformedResponse
        }
        onUsage?(Self.usage(from: payload["usage"]))

        if payload["stop_reason"] as? String == "refusal" {
            let details = payload["stop_details"] as? [String: Any]
            throw Failure.refused(details?["explanation"] as? String ?? "")
        }
        guard let content = payload["content"] as? [[String: Any]] else {
            throw Failure.malformedResponse
        }
        // tool_use ブロックの input がそのまま構造化データ。
        for block in content where block["type"] as? String == "tool_use" {
            if let input = block["input"] {
                return try JSONSerialization.data(withJSONObject: input)
            }
        }
        throw Failure.noToolCall
    }

    // MARK: - 共通

    /// プロンプトは日本語で書いてあるが、書かせる文章はユーザーの言語に揃える。
    /// 迷ったときの既定は、アプリがいま表示している言語。
    static var languageInstruction: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        let language = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        return """


            # 出力の言語
            見出し・本文・フォルダ名・理由など、ユーザーが読む文章はユーザーが書いている言語で書くこと。
            どの言語か判断がつかないときは \(language) で書く。プロンプト中の日本語の例に引きずられないこと。
            """
    }

    /// 402 だけは他と区別する。無料枠の使い切りもここに来るので、
    /// 画面はエラーではなく Paywall を出したい。
    /// `model` はこの呼び出しのモデル。Max（Opus）で呼んでいたら、月の上限で Max を案内しない。
    static func failure(status: Int, body: Data, model: String = ClaudeClient.model) -> Failure {
        let text = String(data: body, encoding: .utf8) ?? ""
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
            .flatMap { $0?["error"] as? [String: Any] }

        switch status {
        case 402:
            return .needsPro(error?["message"] as? String
                             ?? String(localized: "This feature requires a Pro subscription"))
        case 429 where error?["scope"] as? String == "monthly":
            return .monthlyLimitReached(offersMax: model != maxModel)
        case 429 where error?["scope"] as? String == "total":
            return .trialLimitReached
        default:
            logger.error("gateway returned \(status): \(text, privacy: .public)")
            return .http(status: status, body: text)
        }
    }

    /// サーバが数えた無料枠の残りを呼び出し側に渡す。
    private func reportFreeQuota(_ response: HTTPURLResponse) {
        guard let feature, let onFreeQuota,
              let used = response.value(forHTTPHeaderField: "x-free-used").flatMap(Int.init)
        else { return }
        onFreeQuota(feature, used)
    }

    /// 応答の `usage` を読む。欠けているフィールドは 0 として扱う
    /// （モデルやエンドポイントによって出る項目が違うため、無いこと自体は異常ではない）。
    static func usage(from value: Any?) -> TokenUsage {
        guard let fields = value as? [String: Any] else { return TokenUsage() }
        return TokenUsage(
            input: (fields["input_tokens"] as? Int) ?? 0,
            output: (fields["output_tokens"] as? Int) ?? 0,
            cacheRead: (fields["cache_read_input_tokens"] as? Int) ?? 0)
    }

    /// ゲートウェイが 401 を返したら、トークンを取り直して 1 回だけやり直す。
    /// サーバの `SESSION_SECRET` を入れ替えると、手元のトークンは期限内でも通らなくなるため
    /// （取り直さないと、アプリを起動し直すまで最長 24 時間ずっと 401 になる）。
    private func send<Payload>(_ body: [String: Any],
                               _ load: (URLRequest) async throws -> (Payload, URLResponse))
        async throws -> (Payload, URLResponse) {
        let first = try await request(body)
        let result = try await load(first)
        guard authorize != nil, (result.1 as? HTTPURLResponse)?.statusCode == 401,
              let sent = first.value(forHTTPHeaderField: "Authorization")?.dropFirst("Bearer ".count)
        else { return result }
        return try await load(try await request(body, rejecting: String(sent)))
    }

    /// - `rejecting`: ゲートウェイに断られたトークン。渡すと取り直したものを載せる。
    private func request(_ body: [String: Any], rejecting rejected: String? = nil) async throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let authorize {
            request.setValue("Bearer \(try await authorize(rejected))", forHTTPHeaderField: "Authorization")
        }
        if let feature {
            request.setValue(feature.rawValue, forHTTPHeaderField: "X-Feature")
        }
        if let claimedPlan {
            request.setValue(claimedPlan.rawValue, forHTTPHeaderField: "X-Plan")
        }
        // 端末トークンは無料枠の判定だけに使う。取れなくても呼び出しは続ける。
        if let deviceToken, let token = await deviceToken() {
            request.setValue(token, forHTTPHeaderField: "X-Device-Token")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
