import Foundation

/// 過去のジャーナルから引き出す（Pro）。対話の中で AI が自分で過去の記録を探しに行くための道具。
///
/// **エージェント型検索（just-in-time）**にしている。埋め込みやベクトル索引を事前に作らず、
/// 手元に持つのはファイルパスという軽い識別子だけ。AI は `glob` でパスを辿り、`grep` で中身を当て、
/// 必要になった時点で `read` で 1 件を読む。PARA のフォルダ構造はシステムプロンプトに載せてあるので、
/// 「この話は /Areas/生活/住まい の話だ」と当たりを付けてから探せる。
///
/// パスは Vault 書き出し（`VaultExporter`）と同じ形にする。
///
///     /Areas/生活/旅行/保険/journal/3152_202609191330.md
enum JournalRecall {

    /// 1 回の返答で道具を呼べる往復の上限。原価が青天井にならないように切る。
    static let maxRounds = 5
    /// 一覧で返すパスの上限。多すぎたら絞り込みを促す。
    static let globLimit = 80
    /// grep で返す行の上限。
    static let grepLimit = 40
    /// grep の 1 行の長さ。前後の文脈は read で読ませる。
    static let lineLimit = 160
    /// read で返す本文の長さ。ジャーナル 1 件ならまず収まる。
    static let readLimit = 6_000

    // MARK: - 道具の定義

    static let tools: [ClaudeClient.Tool] = [
        ClaudeClient.Tool(
            name: "glob",
            description: """
                過去の記録のパスを、パターンで一覧する。新しい順に「パス \\t 日付 \\t 見出し」で返す。
                `*` はフォルダ名 1 つの中、`**` は何階層でも一致する。
                例: `/Areas/生活/**/journal/*.md`（生活の下のジャーナル全部）、`**/*_202609*.md`（2026 年 9 月の記録）、
                `/Projects/**`（Projects の下すべて）
                """,
            schemaJSON: """
                {
                  "type": "object",
                  "properties": {
                    "pattern": { "type": "string", "description": "パスのパターン。/ で始める" }
                  },
                  "required": ["pattern"],
                  "additionalProperties": false
                }
                """),
        ClaudeClient.Tool(
            name: "grep",
            description: """
                過去の記録の見出しと本文を、正規表現（大文字小文字を区別しない）で検索する。
                一致した行を「パス:行番号: 行」で返す。言い換えや表記ゆれは `引っ越し|転居|住み替え` のように並べる。
                """,
            schemaJSON: """
                {
                  "type": "object",
                  "properties": {
                    "pattern": { "type": "string", "description": "正規表現" },
                    "path": { "type": "string", "description": "探す範囲のパスパターン（glob と同じ書き方）。全体なら空文字" }
                  },
                  "required": ["pattern", "path"],
                  "additionalProperties": false
                }
                """),
        ClaudeClient.Tool(
            name: "read",
            description: "記録を 1 件、パスを指定して全文読む。日付・置き場所・本文を返す。",
            schemaJSON: """
                {
                  "type": "object",
                  "properties": {
                    "path": { "type": "string", "description": "glob か grep が返したパス" }
                  },
                  "required": ["path"],
                  "additionalProperties": false
                }
                """),
    ]

    /// 対話のシステムプロンプトに足す部分。フォルダ一覧は対話側がすでに載せている。
    static func systemAddendum(today: Date = Date()) -> String {
        """

        # 過去のジャーナル
        この人がこれまでに書いた記録を、道具（glob / grep / read）で探して読めます。
        記録は上のフォルダの下に `<フォルダのパス>/<層>/<コード>_<yyyyMMddHHmm>.md` で置かれています。
        層は journal（その日その時の記録）・raw（集めた情報の原本＝生データ）・knowledge（raw と journal から調合した本人の傾向）。
        今日は \(Format.dayKey(for: today)) です。

        ## いつ探すか
        - 最後のユーザーの発言に `<search_intent>` が付いていたら、それが探す合図。
          アプリが会話から読み取った「知りたいこと・フォルダ・言葉・期間」なので、それを手がかりに探す
        - 付いていないときは、「あの時どうしてたっけ」「どうしよう」と本人が過去の自分を頼りたい様子のときだけ探す。
          ただの報告や雑談には探さない

        ## 探し方
        1. 当たりを付けたフォルダを `glob` で一覧する。
           期間が読み取れていれば、道具はまずその期間から探し、無ければ全期間に広げて返す
        2. 言葉で当てるなら `grep`。探す言葉を `|` で並べる
        3. 手がかりになりそうなものだけ `read` する。全部は読まない
        4. 空振りしたら、別のフォルダや言い換えで 1〜2 回だけ探し直す

        ## 語りかけ方
        - 見つけたら、日付と中身を具体的に添えて返す（「9 月 19 日に、〜と書いていましたね」）
        - 過去の本人の判断・やり方・そのときの気持ちを材料に、今どうするかを本人が考えられるように問いかける。
          答えを押し付けない。一般論の教訓にまとめ直さない
        - 見つからなければ、無理に作らずそう伝える。記録に無いことを「書いていた」と言ってはいけない
        """
    }

    // MARK: - 仮想のファイル階層（純粋関数・検証対象）

    /// 記録 1 件のパス。
    static func path(of entry: NoteWithNode) -> String {
        "\(entry.node.path)/\(entry.note.layer.directoryName)/\(entry.note.filename)"
    }

    /// `glob`。新しい順。
    static func glob(_ pattern: String, in entries: [NoteWithNode]) -> String {
        guard let matcher = PathPattern(pattern) else { return "パターンが空です" }
        let hits = entries
            .filter { matcher.matches(path(of: $0)) }
            .sorted { $0.note.occurredAt > $1.note.occurredAt }
        guard !hits.isEmpty else { return noRecords }

        var lines = hits.prefix(globLimit).map {
            "\(path(of: $0))\t\(Format.dayKey(for: $0.note.occurredAt))\t\($0.note.title)"
        }
        if hits.count > globLimit {
            lines.append("…ほか \(hits.count - globLimit) 件。パターンを絞ってください")
        }
        return lines.joined(separator: "\n")
    }

    /// `grep`。見出しを 1 行目として、本文の各行と一緒に検索する。新しい記録から順に返す。
    static func grep(_ pattern: String, scope: String, in entries: [NoteWithNode]) -> String {
        guard !pattern.isEmpty else { return "パターンが空です" }
        let regex = (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
            ?? (try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern),
                                         options: [.caseInsensitive]))
        guard let regex else { return "パターンを解釈できません" }
        let matcher = PathPattern(scope)

        var lines: [String] = []
        var total = 0
        for entry in entries.sorted(by: { $0.note.occurredAt > $1.note.occurredAt }) {
            let filePath = path(of: entry)
            if let matcher, !matcher.matches(filePath) { continue }

            let textLines = [entry.note.title] + entry.note.body.components(separatedBy: .newlines)
            for (index, line) in textLines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard regex.firstMatch(in: line, range: range) != nil else { continue }
                total += 1
                if lines.count < grepLimit {
                    lines.append("\(filePath):\(index + 1): \(line.prefix(lineLimit))")
                }
            }
        }
        guard total > 0 else { return noLines }
        if total > grepLimit {
            lines.append("…ほか \(total - grepLimit) 行。範囲かパターンを絞ってください")
        }
        return lines.joined(separator: "\n")
    }

    /// `read`。見つからなければ nil。
    static func read(_ filePath: String, in entries: [NoteWithNode]) -> String? {
        guard let entry = entries.first(where: { path(of: $0) == filePath }) else { return nil }
        var body = entry.note.body
        if body.count > readLimit {
            body = String(body.prefix(readLimit)) + "\n…（以下 \(body.count - readLimit) 文字を省略）"
        }
        return """
            path: \(filePath)
            date: \(Format.fileTimestamp.string(from: entry.note.occurredAt))
            para: \(entry.node.para.title)
            layer: \(entry.note.layer.directoryName)

            # \(entry.note.title)

            \(body)
            """
    }

    /// 探しているあいだ画面に出す一言。
    static func status(tool name: String, input: Data) -> String {
        let fields = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        switch name {
        case "grep":
            let pattern = (fields["pattern"] as? String ?? "").replacingOccurrences(of: "|", with: " / ")
            return String(localized: "Searching past journals for “\(pattern)”…")
        case "read":
            let file = (fields["path"] as? String ?? "").split(separator: "/").suffix(3).joined(separator: "/")
            return String(localized: "Reading \(file)…")
        default:
            return String(localized: "Looking through past journals…")
        }
    }

    static let noRecords = "一致する記録はありません"
    static let noLines = "一致する行はありません"

    /// 検索意図の期間で絞ってから道具を実行する。期間内で空振りしたら、全期間でやり直して返す
    /// （期間は AI が普段の言葉から読んだものなので、読み違えて絞りすぎることがある）。
    static func run(tool name: String, input: Data, entries: [NoteWithNode],
                    intent: RecallIntent?) -> (text: String, isError: Bool) {
        guard let intent, intent.hasPeriod else { return run(tool: name, input: input, entries: entries) }
        let scoped = run(tool: name, input: input, entries: intent.scope(entries))
        let missed = scoped.isError || scoped.text == noRecords || scoped.text == noLines
        guard missed else { return scoped }
        let widened = run(tool: name, input: input, entries: entries)
        if widened.isError || widened.text == noRecords || widened.text == noLines { return scoped }
        return ("（\(intent.since.isEmpty ? "…" : intent.since) 〜 \(intent.until.isEmpty ? "…" : intent.until) には無かったので、全期間から探しました）\n"
                + widened.text, false)
    }

    /// 道具を 1 つ実行する。`input` は tool_use ブロックの input（JSON）。
    /// 失敗は例外にせず、AI に読ませる文と `isError` で返す（次の手を AI に考えさせる）。
    static func run(tool name: String, input: Data, entries: [NoteWithNode]) -> (text: String, isError: Bool) {
        let fields = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        let string = { (key: String) in (fields[key] as? String ?? "").trimmingCharacters(in: .whitespaces) }

        switch name {
        case "glob":
            return (glob(string("pattern"), in: entries), false)
        case "grep":
            return (grep(string("pattern"), scope: string("path"), in: entries), false)
        case "read":
            if let text = read(string("path"), in: entries) { return (text, false) }
            return ("そのパスの記録はありません。glob か grep が返したパスをそのまま使ってください", true)
        default:
            return ("知らない道具です: \(name)", true)
        }
    }
}

/// `*` と `**` だけの glob。`*` は / をまたがず、`**` はまたぐ。
/// 末尾の `/` や `/**` は「その下すべて」。
struct PathPattern {

    private let regex: NSRegularExpression

    init?(_ pattern: String) {
        var source = pattern.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return nil }
        if !source.hasPrefix("/") && !source.hasPrefix("**") { source = "/" + source }
        if source.hasSuffix("/") { source += "**" }

        var expression = "^"
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if character == "*" {
                if next < source.endIndex, source[next] == "*" {
                    // `**/` は 0 階層にも一致させる（/Areas/**/journal は /Areas/journal も拾う）。
                    let afterStars = source.index(after: next)
                    if afterStars < source.endIndex, source[afterStars] == "/" {
                        expression += "(?:.*/)?"
                        index = source.index(after: afterStars)
                    } else {
                        expression += ".*"
                        index = afterStars
                    }
                    continue
                }
                expression += "[^/]*"
            } else if character == "?" {
                expression += "[^/]"
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = next
        }
        // フォルダを指したときは、その下の記録すべてに一致させる。
        expression += "(?:/.*)?$"

        guard let regex = try? NSRegularExpression(pattern: expression, options: [.caseInsensitive]) else {
            return nil
        }
        self.regex = regex
    }

    func matches(_ path: String) -> Bool {
        regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }
}
