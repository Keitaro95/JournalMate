import Foundation

// MARK: - 日時の出どころ

/// 取り込んだメモの日時を、どこから復元したか。
///
/// メモ.app から書き出したファイルは、**ファイルの作成日が「書き出した日」になる**。
/// 元のメモ作成日を運べる経路はファイル名か frontmatter しかないので、
/// そこから取れたのか代用したのかを必ず区別して数え、取れていなければ画面で警告する。
enum MemoDateSource: String, Sendable, CaseIterable {
    case frontmatter
    case filename
    case fileCreated
    case fileModified
    case importedNow

    /// 元のメモ作成日そのものと言えるか。false は「書き出した日」での代用。
    var carriesOriginalDate: Bool {
        self == .frontmatter || self == .filename
    }

    var label: String {
        switch self {
        case .frontmatter: return String(localized: "occurred in frontmatter")
        case .filename: return String(localized: "Date in file name")
        case .fileCreated: return String(localized: "File creation date (the export date)")
        case .fileModified: return String(localized: "File modification date (the export date)")
        case .importedNow: return String(localized: "Time of import")
        }
    }
}

// MARK: - 取り込み単位

/// 外部メモ 1 件を、DB に入れる直前まで均した形。
struct ImportedMemo: Sendable, Identifiable {
    var id: String { sourceURL }

    var title: String
    var body: String
    /// カレンダーが並べる軸。**元のメモ作成日**をここに入れる。
    var occurredAt: Date
    var dateSource: MemoDateSource
    /// 元の保管場所。受信箱の下の区画になる。深さは 2 までに抑える。
    var folderComponents: [String]
    /// 選んだフォルダからの相対パス。二重取り込みの判定キー。
    var sourceURL: String
    var layer: Layer
    /// 自分が書き出した Vault を戻すときだけ入る（"/Areas/生活/旅行/保険"）。
    var restorePath: String?
}

/// 読み取り結果。読めなかったファイルも落とさずに数える。
struct MemoScanResult: Sendable {
    var memos: [ImportedMemo] = []
    var unreadable: [String] = []
}

/// 取り込みの結果。画面がそのまま読み上げられる粒度にする。
struct ImportSummary: Sendable {
    var imported = 0
    var skipped = 0
    var unreadable = 0
    var dateSources: [MemoDateSource: Int] = [:]
    var folders: [String] = []

    /// 元のメモ作成日を復元できた件数。
    var withOriginalDate: Int {
        dateSources.filter { $0.key.carriesOriginalDate }.values.reduce(0, +)
    }

    /// 書き出した日で代用した件数。ここが 0 でないならショートカットの設定が足りない。
    var withSubstitutedDate: Int {
        dateSources.filter { !$0.key.carriesOriginalDate }.values.reduce(0, +)
    }
}

// MARK: - インポータ

/// `VaultExporter` の逆。外部のメモフォルダを読み、受信箱へ raw として積む。
///
/// 取り込み時点では AI を通さない。まず全件を確実に入れ、分類は後から
/// `move` で引き直す（本文は触らない）＝ 既存の非破壊方針に揃える。
enum MemoImporter {

    static let acceptedExtensions: Set<String> = ["md", "markdown", "txt", "text"]

    /// 受信箱の置き場所。PARA の「義務ではない興味・学習」に仮置きする。
    /// 新しく作るときは表示言語の名前にする。
    static var inboxTitle: String { String(localized: "Inbox") }
    /// 受信箱とみなす名前。フォルダ名は DB に残るので、表示言語を切り替えたあとも
    /// どちらの言語で作られた受信箱も見失わないようにする。
    static let inboxTitles: Set<String> = ["受信箱", "Inbox"]
    static let inboxPara: Para = .resources

    // MARK: 読み取り

    static func scan(directory: URL) throws -> MemoScanResult {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return MemoScanResult() }

        let base = directory.standardizedFileURL.path
        var result = MemoScanResult()

        for case let url as URL in enumerator {
            guard acceptedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { continue }

            let relative = relativePath(of: url, under: base)
            // 自分が書き出した Vault を戻すとき、トップの見取り図はノートではない。
            guard relative.caseInsensitiveCompare("README.md") != .orderedSame else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                result.unreadable.append(relative)
                continue
            }
            result.memos.append(parse(
                text: text,
                filename: url.lastPathComponent,
                relativePath: relative,
                fileCreatedAt: values?.creationDate,
                fileModifiedAt: values?.contentModificationDate))
        }

        result.memos.sort { $0.occurredAt < $1.occurredAt }
        return result
    }

    static func relativePath(of url: URL, under base: String) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return url.lastPathComponent }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: 1 件を均す

    static func parse(text: String, filename: String, relativePath: String,
                      fileCreatedAt: Date?, fileModifiedAt: Date?) -> ImportedMemo {

        let (fields, afterFrontmatter) = splitFrontmatter(text)
        let stamped = timestamp(inFilename: filename)

        // --- 日時。元のメモ作成日を運べる経路から順に当たる ---
        let resolved: (date: Date, source: MemoDateSource)
        if let raw = fields["occurred"], let date = isoDate(raw) {
            resolved = (date, .frontmatter)
        } else if let stamped {
            resolved = (stamped.date, .filename)
        } else if let fileCreatedAt {
            resolved = (fileCreatedAt, .fileCreated)
        } else if let fileModifiedAt {
            resolved = (fileModifiedAt, .fileModified)
        } else {
            resolved = (Date(), .importedNow)
        }

        // --- 見出しと本文 ---
        var title = fields["title"] ?? ""
        var body = afterFrontmatter
        if title.isEmpty, let lead = leadingTitle(of: body) {
            title = lead.title
            // 見出しとして使い切った行だけ本文から落とす。切り詰めた行は残す。
            if lead.consumed { body = lead.rest }
        }
        if title.isEmpty { title = stamped?.remainder ?? "" }
        if title.isEmpty { title = (filename as NSString).deletingPathExtension }

        return ImportedMemo(
            title: title,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            occurredAt: resolved.date,
            dateSource: resolved.source,
            folderComponents: folderComponents(of: relativePath),
            sourceURL: "file://" + relativePath,
            layer: fields["layer"].flatMap(Layer.init(rawValue:)) ?? .raw,
            restorePath: fields["path"])
    }

    /// 相対パスの「ファイルが入っていたフォルダ」。受信箱の下に同じ名前で作る。
    /// 深さは 2 までに抑える（受信箱を足して 3 階層 ＝ 既存の設計方針の上限）。
    static func folderComponents(of relativePath: String) -> [String] {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return [] }
        return Array(parts.dropLast().prefix(2))
    }

    // MARK: ファイル名の日付

    /// 長いものから順に試す。`2026-09-19T13-30` が `2026-09-19` に先に食われないようにする。
    private static let filenameFormats: [(length: Int, format: String)] = [
        (19, "yyyy-MM-dd'T'HH-mm-ss"),
        (16, "yyyy-MM-dd'T'HH-mm"),
        (16, "yyyy-MM-dd HH-mm"),
        (16, "yyyy-MM-dd_HH-mm"),
        (14, "yyyyMMddHHmmss"),
        (12, "yyyyMMddHHmm"),
        (10, "yyyy-MM-dd"),
        (8, "yyyyMMdd"),
    ]

    /// ファイル名の先頭に埋め込まれた日時を読む。推奨は `yyyyMMddHHmm`
    /// （`Format.fileTimestamp` と同じ形。ジャーナルのファイル名と揃う）。
    static func timestamp(inFilename filename: String) -> (date: Date, remainder: String)? {
        let stem = (filename as NSString).deletingPathExtension
        for (length, format) in filenameFormats {
            guard stem.count >= length else { continue }
            let head = String(stem.prefix(length))
            // 区切りの直後で切れていること。"20260919" が "202609192件" を食わないように。
            let next = stem.count > length ? stem[stem.index(stem.startIndex, offsetBy: length)] : "_"
            guard !next.isNumber else { continue }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            guard let date = formatter.date(from: head) else { continue }

            let remainder = String(stem.dropFirst(length))
                .trimmingCharacters(in: CharacterSet(charactersIn: "_- 　"))
            return (date, remainder)
        }
        return nil
    }

    // MARK: frontmatter と見出し

    /// `VaultExporter` が書いた YAML frontmatter を読み戻す。無ければ素通し。
    static func splitFrontmatter(_ text: String) -> (fields: [String: String], body: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else { return ([:], text) }

        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty { fields[key] = value }
        }
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (fields, body)
    }

    /// 本文の先頭行を見出しに使う。メモ.app は 1 行目がそのままメモの名前になる。
    /// 長すぎる行は本文の一部なので、切り詰めて見出しにしつつ本文からは落とさない。
    static func leadingTitle(of body: String) -> (title: String, rest: String, consumed: Bool)? {
        let lines = body.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return nil }

        let stripped = lines[index]
            .trimmingCharacters(in: .whitespaces)
            .drop(while: { $0 == "#" })
            .trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else { return nil }

        if stripped.count > 60 {
            return (String(stripped.prefix(60)), body, false)
        }
        let rest = lines[(index + 1)...].joined(separator: "\n")
        return (stripped, rest, true)
    }

    private static func isoDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        return Format.fileTimestamp.date(from: text)
    }

    // MARK: 投入

    /// 読み取った結果を DB に入れる。1 トランザクションで済ませる。
    @MainActor
    @discardableResult
    static func importMemos(_ scan: MemoScanResult, into store: Store) throws -> ImportSummary {
        var summary = ImportSummary()
        summary.unreadable = scan.unreadable.count

        let already = try store.importedSourceURLs()
        var folders: Set<String> = []

        try store.batch {
            for memo in scan.memos {
                guard !already.contains(memo.sourceURL) else {
                    summary.skipped += 1
                    continue
                }
                let node = try destination(for: memo, in: store)
                try store.createNote(in: node, layer: memo.layer, title: memo.title,
                                     body: memo.body, occurredAt: memo.occurredAt,
                                     sourceURL: memo.sourceURL)
                summary.imported += 1
                summary.dateSources[memo.dateSource, default: 0] += 1
                folders.insert(node.path)
            }
        }

        summary.folders = folders.sorted()
        try store.reloadRoots()
        return summary
    }

    /// 置き場所を決める。自分が書き出した Vault なら元の位置へ戻し、
    /// 外部のメモなら受信箱の下に元のフォルダ名で作る。
    @MainActor
    private static func destination(for memo: ImportedMemo, in store: Store) throws -> Node {
        if let restore = memo.restorePath,
           let node = try restoreNode(path: restore, in: store) {
            return node
        }
        return try store.ensureFolder(para: inboxPara,
                                      components: [try store.inboxTitle(in: inboxPara)]
                                          + memo.folderComponents)
    }

    /// "/Areas/生活/旅行/保険" を PARA 名 + 以下の階層に割り、無ければ作ってたどる。
    @MainActor
    private static func restoreNode(path: String, in store: Store) throws -> Node? {
        let parts = path.split(separator: "/").map(String.init)
        guard let head = parts.first,
              let para = Para.allCases.first(where: { $0.title == head })
        else { return nil }
        return try store.ensureFolder(para: para, components: Array(parts.dropFirst()))
    }
}
