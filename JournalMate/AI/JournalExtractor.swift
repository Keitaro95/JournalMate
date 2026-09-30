import Foundation

/// 保存先の候補 1 つ。既存フォルダか、新しく作るパスのどちらか。
struct SaveDestination: Identifiable, Hashable {
    var para: Para
    /// 既存ノードのコード（"3152"）。空なら `newPath` を作る（それも空なら PARA 直下の受け皿）。
    var nodeCode: String
    /// PARA 直下からのパス（"生活/旅行/保険"）。既存フォルダのときは空。
    var newPath: String
    /// 画面に出すパス（"/Areas/生活/旅行/保険"）。
    var displayPath: String
    /// なぜここなのか、一行で。
    var reason: String

    var id: String { nodeCode.isEmpty ? "new:\(displayPath)" : nodeCode }
    var isNew: Bool { nodeCode.isEmpty }
    /// 会話で名指しされたときに照らし合わせる名前（パスの末尾）。
    var leafTitle: String { displayPath.split(separator: "/").last.map(String.init) ?? "" }

    init(node: Node, reason: String) {
        para = node.para
        nodeCode = node.code
        newPath = ""
        displayPath = node.path
        self.reason = reason
    }

    init(para: Para, newPath: String, reason: String) {
        self.para = para
        nodeCode = ""
        self.newPath = newPath
        if newPath.isEmpty {
            displayPath = para.acceptsNotesAtRoot ? "/\(para.title)" : "/\(para.title)/\(MemoImporter.inboxTitle)"
        } else {
            displayPath = "/\(para.title)/\(newPath)"
        }
        self.reason = reason
    }
}

/// AI が提案したジャーナル。ユーザーが保存先を確かめるまで DB には入れない。
/// 「AI に勝手に書かせない」ための中間物。
struct JournalDraft: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var body: String
    var layer: Layer
    /// 既存ノードのコード（"3152"）。空なら `suggestedPath` で新規作成。
    var nodeCode: String
    var para: Para
    /// 既存に該当がないときの提案パス（"生活/旅行/保険"）。
    var suggestedPath: String
    var occurredAt: Date = Date()
    /// 会話の中で保存先を尋ねるときの一言（「今日の話は引っ越しの段取りでした」）。
    var summary: String = ""
    /// 保存先の候補。先頭が第一候補。空なら確認シートで選んでもらう。
    var destinations: [SaveDestination] = []

    /// 候補を 1 つ選んだ案。PARA は必ず保存先に合わせる（食い違ったまま保存しない）。
    func applying(_ destination: SaveDestination) -> JournalDraft {
        var draft = self
        draft.para = destination.para
        draft.nodeCode = destination.nodeCode
        draft.suggestedPath = destination.newPath
        return draft
    }
}

/// 会話からジャーナルを取り出し、ユーザーが作ったフォルダの中から保存先を選ぶ。
struct JournalExtractor {

    let client: ClaudeClient

    /// ツールの入力そのもの。スキーマと 1 対 1 で対応させる。
    private struct Payload: Decodable {
        struct Candidate: Decodable {
            var node_code: String
            var reason: String
        }
        var title: String
        var body: String
        var layer: String
        var summary: String
        var candidates: [Candidate]
        var new_para: String
        var new_path: String
        var new_reason: String
    }

    private static let tool = ClaudeClient.Tool(
        name: "record_journal",
        description: "会話から、その日その時のジャーナルを 1 件抽出し、保存先の候補を挙げる",
        schemaJSON: """
            {
              "type": "object",
              "properties": {
                "title": {
                  "type": "string",
                  "description": "20 文字程度の見出し。出来事ではなく本人の関心が分かる言い方にする"
                },
                "body": {
                  "type": "string",
                  "description": "Markdown 本文。会話の要点を一人称でまとめる。箇条書き可"
                },
                "layer": {
                  "type": "string",
                  "enum": ["journal", "knowledge", "raw"],
                  "description": "journal = その日その時の記録（既定）、knowledge = raw と journal から調合した本人の傾向（考え方・行動のくせ）、raw = 外部の情報源・リンク・専門家の見解の写し"
                },
                "summary": {
                  "type": "string",
                  "description": "保存先を尋ねる前に添える一文。「今日の話は〜でした。」の形で、何の話だったかを本人に返す"
                },
                "candidates": {
                  "type": "array",
                  "description": "保存先の候補。既存フォルダ一覧にあるコードだけを使い、ふさわしい順に 1〜3 件。どれも当てはまらなければ空配列",
                  "items": {
                    "type": "object",
                    "properties": {
                      "node_code": { "type": "string", "description": "既存フォルダのコード" },
                      "reason": { "type": "string", "description": "なぜここなのか、本人の言葉を引いて一行で" }
                    },
                    "required": ["node_code", "reason"],
                    "additionalProperties": false
                  }
                },
                "new_para": {
                  "type": "string",
                  "enum": ["journal", "projects", "areas", "resources", "archives", ""],
                  "description": "既存フォルダのどれにも当てはまらないときだけ、新しく作るフォルダの PARA。それ以外は空文字"
                },
                "new_path": {
                  "type": "string",
                  "description": "新しく作るフォルダのパス。PARA 名を含めず、PARA の直下から書く（例: 生活/旅行/保険）。深さ 3 まで。不要なら空文字"
                },
                "new_reason": {
                  "type": "string",
                  "description": "新しいフォルダが要る理由を一行で。不要なら空文字"
                }
              },
              "required": ["title", "body", "layer", "summary", "candidates", "new_para", "new_path", "new_reason"],
              "additionalProperties": false
            }
            """)

    /// 会話ログと現在のツリーを渡して、ジャーナル案と保存先の候補をもらう。
    func extract(from messages: [Message], tree: [Node]) async throws -> JournalDraft {
        let folders = Self.candidateNodes(from: tree)

        let system = """
            あなたはユーザーの思考のアーキビストです。会話を読み、その日その時のジャーナルを 1 件作り、
            **ユーザー自身が作ったフォルダの中から**保存先を選びます。

            # ユーザーのフォルダ（コード \\t パス）
            最初の設定で、本人が「話題にしたい領域」として作ったものです。保存先はまずここから選びます。
            \(Self.folderList(folders))

            # 保存先の選び方
            1. 会話の中心の話題が、上のどのフォルダの話かを考える。本人がフォルダ名と違う言葉で話していても、
               指しているものが同じならそのフォルダを選ぶ
            2. 特定の取り組みや話題に結びつかない日々の出来事・気分・雑感なら、Journal（コード \(Para.journal.leadingDigit)、/\(Para.journal.title)）を選ぶ。
               Journal は PARA に振り分けない、ふつうのジャーナルの置き場。無理に PARA のフォルダへ寄せない
            3. 候補が複数の PARA にまたがるときは、今の本人との関わり度合いで順位を付ける（PARA / Tiago Forte）
               - projects: 締め切りや「終わった」と言える完了の条件がある取り組み
               - areas: 終わりがなく、水準を保ち続ける責任（健康、家計、仕事の役割、家族）
               - resources: 義務ではない興味・学習・参考情報
               - archives: 終わった・手を離れたもの
            4. 第一候補を先頭に、1〜3 件を candidates に入れる。コードは上の一覧にあるものだけを使う
            5. どれにも当てはまらないときだけ、candidates を空にして new_para / new_path を提案する。
               新しいフォルダは本人の言葉で名付け、深さ 3 までに抑える

            # 層
            - raw: 生データ置き場。外部の情報源、専門家の見解、リンク。書き換えない
            - knowledge: raw と journal から調合した、本人の傾向（考え方・行動のくせ）
            - journal: その日その時の記録

            本文はユーザー本人の言葉を尊重し、事実を足さないでください。
            """

        let transcript = Self.transcript(of: messages)
        // 会話は 1 本の user メッセージにまとめて渡す。最後が assistant の turn だと
        // 「続きを書け」（prefill）と解釈され、Opus 5 / Sonnet 5 では 400 になる。
        let data = try await client.callTool(
            system: system,
            turns: [ClaudeClient.Turn(role: "user", text: "以下が今日の会話です。\n\n\(transcript)")],
            tool: Self.tool)
        let payload = try JSONDecoder().decode(Payload.self, from: data)

        let destinations = Self.destinations(
            candidates: payload.candidates.map { ($0.node_code, $0.reason) },
            newPara: payload.new_para, newPath: payload.new_path, newReason: payload.new_reason,
            folders: folders)
        let first = destinations.first ?? SaveDestination(para: .journal, newPath: "", reason: "")

        return JournalDraft(
            title: payload.title,
            body: payload.body,
            layer: Layer(rawValue: payload.layer) ?? .journal,
            nodeCode: first.nodeCode,
            para: first.para,
            suggestedPath: first.newPath,
            summary: payload.summary,
            destinations: destinations)
    }

    // MARK: - 判定（純粋関数。Verification から呼ぶ）

    /// 保存先の候補。受信箱とその下、PARA ルートは外す
    /// （受信箱に入れても整理にならないし、ルート直置きは避けたい）。
    /// Journal のルートだけは残す（そこがふつうのジャーナルの置き場なので）。
    static func candidateNodes(from tree: [Node]) -> [Node] {
        tree.filter { node in
            (node.parentID != nil || node.para.acceptsNotesAtRoot)
                && !MemoImporter.inboxTitles.contains(node.title)
                && !MemoImporter.inboxTitles.contains { node.path.contains("/\($0)/") }
        }
    }

    /// AI に見せるフォルダ一覧。
    static func folderList(_ folders: [Node]) -> String {
        folders.isEmpty ? "（まだありません）"
            : folders.map { "\($0.code)\t\($0.path)" }.joined(separator: "\n")
    }

    /// 会話を 1 本のテキストにする。
    static func transcript(of messages: [Message]) -> String {
        messages.map { "\($0.role == .user ? "ユーザー" : "AI"): \($0.content)" }
            .joined(separator: "\n\n")
    }

    /// AI の答えを、実在する保存先の候補に直す。
    /// - 一覧に無いコード・重複は捨てる（AI が作ったコードで受け皿に落ちないように）
    /// - PARA はフォルダ側から取る（AI の言う PARA とフォルダが食い違っても、フォルダを正とする）
    /// - 新しいパスは頭の "/" と PARA 名を落とす。既存のフォルダと同じなら既存を使う
    static func destinations(candidates: [(code: String, reason: String)],
                             newPara: String, newPath: String, newReason: String,
                             folders: [Node]) -> [SaveDestination] {
        var result: [SaveDestination] = []
        for candidate in candidates {
            let code = candidate.code.trimmingCharacters(in: .whitespaces)
            guard let node = folders.first(where: { $0.code == code }),
                  !result.contains(where: { $0.nodeCode == code }) else { continue }
            result.append(SaveDestination(node: node, reason: candidate.reason))
        }

        if let (para, path) = normalizedNewPath(newPath, para: Para(rawValue: newPara)) {
            if let existing = folders.first(where: { $0.path == "/\(para.title)/\(path)" }) {
                if !result.contains(where: { $0.nodeCode == existing.code }) {
                    result.append(SaveDestination(node: existing, reason: newReason))
                }
            } else {
                result.append(SaveDestination(para: para, newPath: path, reason: newReason))
            }
        }
        return Array(result.prefix(4))
    }

    /// "/Areas/生活/旅行" や "Areas/生活" の PARA 名を外し、PARA と PARA 直下からのパスに分ける。
    /// パスの頭の PARA 名は `para` より優先する（パスに書いてある方が本人に見える場所だから）。
    static func normalizedNewPath(_ raw: String, para: Para?) -> (Para, String)? {
        var components = raw.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var para = para
        if let head = components.first,
           let named = Para.allCases.first(where: { $0.title.caseInsensitiveCompare(head) == .orderedSame }) {
            para = named
            components.removeFirst()
        }
        guard let para, !components.isEmpty else { return nil }
        return (para, components.prefix(3).joined(separator: "/"))
    }

    /// 保存先を尋ねたあとに打たれた返事を、候補かフォルダに対応づける。
    /// 決められなければ nil（推測で保存しない）。
    static func resolveReply(_ text: String, destinations: [SaveDestination],
                             folders: [Node]) -> SaveDestination? {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return nil }

        // 名前が出ていれば、候補 → 全フォルダの順で探す。長い名前ほど具体的なので優先する。
        // 「はい、住まいの方で」のように名前と相づちが混ざるので、相づちより先に見る。
        let named = destinations
            .filter { !$0.leafTitle.isEmpty && reply.contains($0.leafTitle) }
            .sorted { $0.leafTitle.count > $1.leafTitle.count }
        if let match = named.first,
           named.filter({ $0.leafTitle.count == match.leafTitle.count }).count == 1 {
            return match
        }
        let nodes = folders
            .filter { reply.contains($0.title) }
            .sorted { $0.title.count > $1.title.count }
        if let match = nodes.first, nodes.filter({ $0.title == match.title }).count == 1 {
            return SaveDestination(node: match, reason: "")
        }

        // 名前が無く「はい」「それで」なら第一候補。
        let yes = ["はい", "うん", "それで", "そこで", "ok", "yes", "いいよ", "お願い"]
        if yes.contains(where: { reply.lowercased().hasPrefix($0) }) {
            return destinations.first
        }
        return nil
    }

    /// 「やめる」系の返事か。
    static func isCancelReply(_ text: String) -> Bool {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["やめ", "いいえ", "保存しない", "キャンセル", "no", "cancel"].contains { reply.hasPrefix($0) }
    }
}
