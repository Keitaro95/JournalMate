import Foundation

/// 過去のジャーナルを探す前に読み取る、今回の検索意図。
///
/// 本人は「どうしよう」「前にもあった気がする」としか言わないことが多い。そのまま grep させると
/// 言葉が拾えず空振りするので、先に **何を過去から知りたいのか・どこに・どんな言葉で書いてありそうか**
/// を 1 回の構造化出力で決めてから、検索（`JournalRecall`）を走らせる。
struct RecallIntent: Equatable, Sendable {
    /// 今、過去の記録を探すと役に立つか。false なら道具を渡さずに普通に返す。
    var needsRecall: Bool
    /// 過去から知りたいこと。一文（「前回の引っ越しで業者をどう選んだか」）。
    var intent: String
    /// 当たりを付けるフォルダのコード。実在するものだけに絞ってある。
    var folderCodes: [String]
    /// 探す言葉。本人の言い回しに、言い換え・表記ゆれを足したもの。
    var keywords: [String]
    /// 発言から汲み取った期間（yyyy-MM-dd、両端を含む）。**検索の前に、道具に渡す記録をここで絞る。**
    /// 本人に決まった言い方はさせない。「最近」「この前」のような普段の言葉や話の中身から AI が読む。
    /// 時期を限る手がかりが無ければ両方空 ＝ 全期間。片方だけでもよい。
    /// 読み違えて絞りすぎても、期間内で見つからなければ全期間に広げる（`JournalRecall.run(tool:input:entries:intent:)`）。
    var since: String
    var until: String

    var hasPeriod: Bool { !since.isEmpty || !until.isEmpty }

    /// 検索の前の絞り込み。期間の外の記録は、まず道具から見えなくする。
    /// 日付は記録の `dayKey`（端末のタイムゾーンの yyyy-MM-dd）で比べる。
    func scope(_ entries: [NoteWithNode]) -> [NoteWithNode] {
        guard hasPeriod else { return entries }
        return entries.filter {
            (since.isEmpty || $0.note.dayKey >= since) && (until.isEmpty || $0.note.dayKey <= until)
        }
    }
}

/// いまの発言から検索意図を読み取る。
///
/// 読ませるのは **いまの発言・本人のフォルダ一覧・今日の日付だけ**。それまでの会話は読ませない
/// （意図はいまの一言から決める。会話を足すと前の話題に引きずられるし、1 日ぶんを毎回読み直すと高い）。
struct RecallIntentReader {

    let client: ClaudeClient

    private struct Payload: Decodable {
        var needs_recall: Bool
        var intent: String
        var folder_codes: [String]
        var keywords: [String]
        var since: String
        var until: String
    }

    static let tool = ClaudeClient.Tool(
        name: "read_search_intent",
        description: "ユーザーの発言から、過去のジャーナルを探す意図を読み取る",
        schemaJSON: """
            {
              "type": "object",
              "properties": {
                "needs_recall": {
                  "type": "boolean",
                  "description": "今、本人の過去の記録を探すと返答が良くなるか。報告・雑談・今日の出来事を話しているだけなら false"
                },
                "intent": {
                  "type": "string",
                  "description": "過去の記録から何を知りたいのかを一文で。本人の立場で具体的に（例: 前に引っ越したとき、業者をどう選んで何に困ったか）。false なら空文字"
                },
                "folder_codes": {
                  "type": "array",
                  "items": { "type": "string" },
                  "description": "書いてありそうなフォルダのコード。一覧にあるものだけ、可能性の高い順に最大 3 つ"
                },
                "keywords": {
                  "type": "array",
                  "items": { "type": "string" },
                  "description": "記録の中に書かれていそうな言葉。本人の言い回しに、言い換え・表記ゆれ・関連語を足して最大 8 つ"
                },
                "since": { "type": "string", "description": "発言から読み取れる期間の始まり（yyyy-MM-dd）。時期を限る手がかりが無ければ空文字（全期間）" },
                "until": { "type": "string", "description": "発言から読み取れる期間の終わり（yyyy-MM-dd、その日を含む）。無ければ空文字" }
              },
              "required": ["needs_recall", "intent", "folder_codes", "keywords", "since", "until"],
              "additionalProperties": false
            }
            """)

    func read(utterance: String, folders: [Node], today: Date = Date()) async throws -> RecallIntent {
        let data = try await client.callTool(
            system: Self.system(folders: folders, today: today),
            turns: [ClaudeClient.Turn(role: "user", text: Self.prompt(for: utterance))],
            tool: Self.tool,
            maxTokens: 1_000)
        return try Self.decode(data, folders: folders)
    }

    // MARK: - 入力の組み立てと読み取り（純粋関数・検証対象）

    static func system(folders: [Node], today: Date) -> String {
        """
        あなたは、ユーザーの日記アプリの中で「過去の記録を探す前の聞き取り役」です。
        返答はしません。ユーザーのいまの発言から、本人の過去のジャーナルを探す意図を読み取ります。

        # この人のフォルダ（コード \\t パス）。PARA（Projects / Areas / Resources / Archives）で分けてある
        \(JournalExtractor.folderList(folders))

        今日は \(Format.dayKey(for: today)) です。

        # 読み取り方
        - 言葉の表面ではなく、本人が過去の自分から何を得たいのかを読む
          - 「どうしよう」「迷ってる」→ 前に似た場面でどう判断し、どうなったか
          - 「前にもあった」「あの時どうしてたっけ」→ その出来事の記録そのもの
          - 「また〇〇してしまった」→ 繰り返しのパターンと、そのとき効いたこと
        - ただの報告・雑談・今日の気持ちを話しているだけなら needs_recall は false
        - フォルダは話題から当たりを付ける。本人がフォルダ名と違う言葉で話していても、指しているものが同じなら選ぶ
        - 言葉は、過去の本人が日記に書きそうな形にする（「転職」なら「面接|面談|退職|オファー」も）
        - 期間は検索の前の絞り込みになる。本人は決まった言い方をしないので、普段の言葉と話の中身から読む
          - 日付や月をはっきり言っていればそのまま（「先月」→ 先月の 1 日〜末日、「去年の夏」→ 去年の 6/1〜8/31）
          - 「先月の同じ日」「去年の今日」のように 1 日を指していれば、その日だけ（since と until を同じ日にする）。
            何を書いていたか・何をしていたかを聞くだけで話題が無ければ、keywords は空でよい
          - 「最近」「ここのところ」「この前」→ おおむね直近 1〜2 か月。「ずっと」「前から」→ 限らない
          - 話の中身が時期を決めることもある（「今の案件で」→ その取り組みの間。分からなければ限らない）
          - 時期を限る手がかりが無ければ両方とも空（全期間）。迷ったら空にする
          - 読み違えても、期間内で見つからなければアプリが全期間に広げるので、外すことを恐れなくてよい
        """
    }

    static func prompt(for utterance: String) -> String {
        """
        # ユーザーのいまの発言
        \(utterance)
        """
    }

    /// 一覧に無いフォルダ・空の言葉・重複は捨てる。日付の形が違えば空にする。
    static func decode(_ data: Data, folders: [Node]) throws -> RecallIntent {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let known = Set(folders.map(\.code))
        var seenCodes = Set<String>()
        let codes = payload.folder_codes
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { known.contains($0) && seenCodes.insert($0).inserted }
        var seenWords = Set<String>()
        let words = payload.keywords
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seenWords.insert($0.lowercased()).inserted }
        let day = { (text: String) -> String in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? trimmed : ""
        }
        return RecallIntent(
            needsRecall: payload.needs_recall,
            intent: payload.intent.trimmingCharacters(in: .whitespacesAndNewlines),
            folderCodes: Array(codes.prefix(3)),
            keywords: Array(words.prefix(8)),
            since: day(payload.since),
            until: day(payload.until))
    }

    /// 検索を走らせる返答に添える手がかり。最後のユーザーの発言の後ろに、別のブロックとして付ける。
    /// 本人の発言と取り違えないよう、アプリが読み取ったものだと明記する。
    static func briefing(_ intent: RecallIntent, folders: [Node]) -> String {
        let byCode = Dictionary(folders.map { ($0.code, $0.path) }, uniquingKeysWith: { first, _ in first })
        let places = intent.folderCodes.compactMap { code in byCode[code].map { "\(code) \($0)" } }
        let period = intent.hasPeriod
            ? "\(intent.since.isEmpty ? "…" : intent.since) 〜 \(intent.until.isEmpty ? "…" : intent.until)"
                + "（発言から読み取った期間。道具はまずこの期間から探し、無ければ全期間に広げます）"
            : "指定なし（全期間）"
        return """
            <search_intent>
            アプリが会話から読み取った、今回の検索意図です（本人の発言ではありません）。
            - 知りたいこと: \(intent.intent.isEmpty ? "（読み取れず）" : intent.intent)
            - 当たりを付けるフォルダ: \(places.isEmpty ? "（特定できず）" : places.joined(separator: ", "))
            - 探す言葉: \(intent.keywords.isEmpty ? "（なし）" : intent.keywords.joined(separator: " | "))
            - 期間: \(period)
            これを手がかりに道具で本人の過去の記録を探し、見つけたものを踏まえて返答してください。
            ここで見つからなければ、別のフォルダや言葉でも探してよい。
            </search_intent>
            """
    }
}
