import Foundation

/// DB の中身を「実物の .md ファイル階層」に書き出す。
/// 正は DB だが、いつでも Obsidian 互換の Vault として取り出せることで
/// ロックインを避ける（Markdown は値として持ち、FS は持たない）。
///
/// 同じ Vault に DB の写し（`backupFilename`）も入れておく。.md だけでは
/// ID・作成日時・削除済みが戻らないので、アプリを入れ直したときの復元はこちらで行う。
/// 対話の履歴は写しに入れない（`Store.writeBackup`）。
/// Obsidian は .sqlite を一覧に出さないので、Vault として開いても邪魔にならない。
enum VaultExporter {

    static let backupFilename = "journalmate-backup.sqlite"

    /// 書き出し先のフォルダ URL を返す。
    ///
    ///     Areas/生活/旅行/保険/journal/3152_202609191330.md
    @MainActor
    static func exportVault(from store: Store, to directory: URL) throws -> URL {
        let root = directory.appendingPathComponent("JournalMateBackup", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for node in try store.allNodes() {
            // node.path は "/Areas/生活/旅行/保険"。先頭の / を落として実パスに重ねる。
            let relative = node.path.hasPrefix("/") ? String(node.path.dropFirst()) : node.path
            let nodeDirectory = root.appendingPathComponent(relative, isDirectory: true)

            for layer in Layer.allCases {
                let notes = try store.notes(in: node, layer: layer)
                guard !notes.isEmpty else { continue }
                let layerDirectory = nodeDirectory.appendingPathComponent(layer.directoryName,
                                                                          isDirectory: true)
                try FileManager.default.createDirectory(at: layerDirectory,
                                                        withIntermediateDirectories: true)
                for note in notes {
                    let url = layerDirectory.appendingPathComponent(note.filename)
                    try markdown(for: note, in: node).write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }

        try indexMarkdown(from: store).write(
            to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try store.writeBackup(to: root.appendingPathComponent(backupFilename))
        return root
    }

    /// 書き出した Vault（.zip かフォルダ）から、復元用の写しを一時フォルダに取り出す。
    /// 返す URL は書き換えてよい（`Store.restore(fromBackup:)` がマイグレーションする）。
    static func extractBackup(from source: URL) throws -> URL {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let destination = work.appendingPathComponent(backupFilename)

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            // ファイル App で zip を展開したフォルダ。書き出したフォルダそのものか、その親を選んでもよい。
            // JournalMateVault は名前を変える前の書き出し。
            let candidates = [source]
                + ["JournalMateBackup", "JournalMateVault"].map { source.appendingPathComponent($0) }
            let files = candidates.map { $0.appendingPathComponent(backupFilename) }
            guard let found = files.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            else { throw Store.BackupError.missing }
            try FileManager.default.copyItem(at: found, to: destination)
        } else {
            let zip = try ZipReader(url: source)
            guard let entry = zip.entry(named: backupFilename) else { throw Store.BackupError.missing }
            try zip.extract(entry).write(to: destination)
        }
        return destination
    }

    /// 共有シートに渡せる .zip を作る。
    /// `NSFileCoordinator` の `.forUploading` はフォルダを zip に畳んでくれるので、
    /// 圧縮のためだけに依存を増やさずに済む。
    @MainActor
    static func exportZip(from store: Store) throws -> URL {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let vault = try exportVault(from: store, to: work)

        var coordinatorError: NSError?
        var result: URL?
        var copyError: Swift.Error?

        NSFileCoordinator().coordinate(
            readingItemAt: vault, options: [.forUploading], error: &coordinatorError
        ) { zipped in
            let destination = work.appendingPathComponent("JournalMateBackup.zip")
            do {
                try FileManager.default.moveItem(at: zipped, to: destination)
                result = destination
            } catch {
                copyError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        guard let result else {
            throw CocoaError(.fileWriteUnknown)
        }
        return result
    }

    /// YAML frontmatter 付き Markdown。タグとコードを残すので、
    /// 書き出した先でも PARA と層（raw / knowledge / journal）が追える。
    static func markdown(for note: Note, in node: Node) -> String {
        var lines = [
            "---",
            "code: \(node.code)",
            "para: \(node.para.rawValue)",
            "layer: \(note.layer.rawValue)",
            "path: \(node.path)",
            "title: \(yamlEscaped(note.title))",
            "occurred: \(ISO8601DateFormatter().string(from: note.occurredAt))",
        ]
        if let sourceURL = note.sourceURL {
            lines.append("source: \(yamlEscaped(sourceURL))")
        }
        lines.append("tags: [\(node.para.rawValue), \(note.layer.rawValue), \"\(node.title)\"]")
        lines.append("---")
        lines.append("")
        lines.append("# \(note.title)")
        lines.append("")
        lines.append(note.body)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Vault のトップに置く見取り図。
    @MainActor
    private static func indexMarkdown(from store: Store) throws -> String {
        var lines = ["# JournalMate Vault", "",
                     String(localized: "Notes organized with PARA, split into raw data, journals, and your patterns."), ""]
        for node in try store.allNodes() {
            let indent = String(repeating: "  ", count: node.depth)
            lines.append("\(indent)- `\(node.code)` \(node.title)")
        }
        lines += ["", String(localized: "`journalmate-backup.sqlite` is for restoring into the JournalMate app (Settings > Restore from Backup). Keep it together with this folder.")]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func yamlEscaped(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
