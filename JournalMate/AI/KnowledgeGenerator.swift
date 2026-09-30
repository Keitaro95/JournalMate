import Foundation

/// フォルダの「自分の傾向」（knowledge）を AI に書かせる。
///
/// 材料はそのフォルダ（とその下）にある 2 つだけ。
/// - 生データ（raw）: 人生の指針・向かいたい方向。本人が「こうありたい」と置いたもの
/// - ジャーナル（journal）: 自分の記録。実際にどう考え、どう動いたか
///
/// この 2 つを調合して「実際の自分の傾向」と「指針に照らして向かうべき道」を書き出す。
/// ジャーナルは日付順（ファイル名と同じ `yyyyMMddHHmm` の規則）に並べて渡し、変化も読ませる。
/// 書き出したノートもジャーナルと同じ日付規則のファイル名で保存する（`ParaCode.filename`）。
/// 原本（raw / journal）は書き換えない。
struct KnowledgeGenerator {

    let client: ClaudeClient

    /// 生成に使う材料。どちらも古い順。
    struct Material {
        var raw: [NoteWithNode]
        var journals: [NoteWithNode]

        var isEmpty: Bool { raw.isEmpty && journals.isEmpty }
        /// 材料になったジャーナルの期間（yyyy-MM-dd）。無ければ nil。
        var period: (from: String, to: String)? {
            guard let first = journals.first, let last = journals.last else { return nil }
            return (first.note.dayKey, last.note.dayKey)
        }
    }

    /// 生成結果。ノートの見出しと本文（Markdown）。
    struct Result: Equatable {
        var title: String
        var body: String
    }

    // MARK: - 材料集め

    /// 渡すジャーナルの上限。多すぎると高く遅くなるので、新しいものから残す。
    static let maxJournals = 80
    static let maxRaw = 30
    /// 1 件あたりの本文の上限（文字）。
    static let maxJournalChars = 1_200
    static let maxRawChars = 2_000

    /// このフォルダとその下にある生データとジャーナルを集める。
    /// 子孫は `path` で判定する（`code` の前方一致だと 2 桁以上の番号で隣のフォルダを拾うため）。
    @MainActor
    static func material(in node: Node, store: Store) throws -> Material {
        let nodes = try store.allNodes().filter { isInside($0, of: node) }
        var raw: [NoteWithNode] = []
        var journals: [NoteWithNode] = []
        for child in nodes {
            raw += try store.notes(in: child, layer: .raw).map { NoteWithNode(note: $0, node: child) }
            journals += try store.notes(in: child, layer: .journal).map { NoteWithNode(note: $0, node: child) }
        }
        return trimmed(raw: raw, journals: journals)
    }

    /// 自分自身か、その下のフォルダか。
    static func isInside(_ candidate: Node, of node: Node) -> Bool {
        candidate.id == node.id || candidate.path.hasPrefix(node.path + "/")
    }

    /// 新しいものから上限まで残し、古い順に並べ直す。
    static func trimmed(raw: [NoteWithNode], journals: [NoteWithNode]) -> Material {
        func latest(_ entries: [NoteWithNode], _ limit: Int) -> [NoteWithNode] {
            Array(entries.sorted { $0.note.occurredAt > $1.note.occurredAt }.prefix(limit).reversed())
        }
        return Material(raw: latest(raw, maxRaw), journals: latest(journals, maxJournals))
    }

    // MARK: - 生成

    private struct Payload: Decodable {
        struct Pattern: Decodable {
            var pattern: String
            var evidence: String
        }
        var title: String
        var patterns: [Pattern]
        var gaps: [String]
        var direction: [String]
    }

    private static let tool = ClaudeClient.Tool(
        name: "write_patterns",
        description: "生データ（指針・方向性）とジャーナル（自分の記録）を調合し、本人の傾向と向かうべき道を書き出す",
        schemaJSON: """
            {
              "type": "object",
              "properties": {
                "title": {
                  "type": "string",
                  "description": "20 文字程度の見出し。いまの傾向がひと目で分かる言い方にする"
                },
                "patterns": {
                  "type": "array",
                  "description": "ジャーナルから読み取れる本人の傾向（考え方・行動のくせ）。3〜6 件、強いものから",
                  "items": {
                    "type": "object",
                    "properties": {
                      "pattern": { "type": "string", "description": "傾向を一文で。「〜しがち」「〜のときに〜する」の形" },
                      "evidence": { "type": "string", "description": "根拠になった記録。日付（yyyy-MM-dd）と、本人の言葉を短く" }
                    },
                    "required": ["pattern", "evidence"],
                    "additionalProperties": false
                  }
                },
                "gaps": {
                  "type": "array",
                  "description": "生データの指針・方向性と、実際の傾向とのずれ・重なり。生データが無ければ空",
                  "items": { "type": "string" }
                },
                "direction": {
                  "type": "array",
                  "description": "向かうべき道。指針と傾向を踏まえた、次に取れる具体的な一歩。2〜4 件",
                  "items": { "type": "string" }
                }
              },
              "required": ["title", "patterns", "gaps", "direction"],
              "additionalProperties": false
            }
            """)

    func generate(from material: Material, folder: Node, today: Date = Date()) async throws -> Result {
        let system = """
            あなたはユーザーの思考のアーキビストです。ユーザーのフォルダ「\(folder.path)」にある記録を読み、
            **自分の傾向**と**向かうべき道**を書き出します。

            # 材料
            - 生データ: 本人が集めた人生の指針・向かいたい方向（ベクトル）。「こうありたい」の側
            - ジャーナル: 本人の記録。日付の古い順に並んでいる。「実際はこうだった」の側

            # 書き方
            - 傾向はジャーナルの事実から読む。一度きりの出来事ではなく、繰り返し現れるものを選ぶ
            - 日付の流れを見て、変わってきたこと・続いていることがあれば傾向に含める
            - 根拠には必ず日付と本人の言葉を添える。記録に無いことを足さない
            - 生データの指針と傾向を突き合わせ、ずれと重なりを書く
            - 向かうべき道は、一般論の説教ではなく、この人の指針と傾向から出る具体的な一歩にする
            - 本人に語りかける二人称ではなく、本人が自分のノートに書く一人称の言葉で書く
            - 今日は \(Format.dayKey(for: today)) です
            """

        let data = try await client.callTool(
            system: system,
            turns: [ClaudeClient.Turn(role: "user", text: Self.sourceText(material))],
            tool: Self.tool)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return Self.result(from: payload, material: material)
    }

    // MARK: - 組み立て（純粋関数。Verification から呼ぶ）

    /// AI に渡す材料の本文。生データ → ジャーナル（古い順）の順に並べる。
    static func sourceText(_ material: Material) -> String {
        var lines: [String] = []
        lines.append("# 生データ（指針・方向性）")
        if material.raw.isEmpty {
            lines.append("（なし）")
        }
        for entry in material.raw {
            lines.append("## \(entry.note.title)（\(entry.node.path)）")
            lines.append(String(entry.note.body.prefix(maxRawChars)))
        }
        lines.append("")
        lines.append("# ジャーナル（自分の記録・古い順）")
        if material.journals.isEmpty {
            lines.append("（なし）")
        }
        for entry in material.journals {
            let stamp = Format.fileTimestamp.string(from: entry.note.occurredAt)
            lines.append("## \(entry.note.dayKey) \(entry.note.title)（\(entry.node.code)_\(stamp)）")
            lines.append(String(entry.note.body.prefix(maxJournalChars)))
        }
        return lines.joined(separator: "\n")
    }

    private static func result(from payload: Payload, material: Material) -> Result {
        var lines: [String] = []
        if let period = material.period {
            lines.append(String(localized: "Based on: \(material.raw.count) raw data, \(material.journals.count) journals (\(period.from) – \(period.to))"))
        } else {
            lines.append(String(localized: "Based on: \(material.raw.count) raw data"))
        }
        lines.append("")
        lines.append("## " + String(localized: "My Patterns"))
        for item in payload.patterns {
            lines.append("- \(item.pattern)")
            if !item.evidence.isEmpty {
                lines.append("  - \(item.evidence)")
            }
        }
        if !payload.gaps.isEmpty {
            lines.append("")
            lines.append("## " + String(localized: "Compared with My Principles"))
            lines += payload.gaps.map { "- \($0)" }
        }
        lines.append("")
        lines.append("## " + String(localized: "The Path Ahead"))
        lines += payload.direction.map { "- \($0)" }
        return Result(title: payload.title, body: lines.joined(separator: "\n"))
    }
}
