import Foundation
import Observation

/// DB への唯一の出入口。画面はここだけを見る。
@MainActor
@Observable
final class Store {

    private let db: SQLiteDatabase

    /// ルート 5 件（Journal + PARA）。ツリー画面の最上段。
    private(set) var roots: [Node] = []
    /// 直近の失敗。画面がアラートで出す。
    var lastError: String?

    // MARK: - 起動

    init(db: SQLiteDatabase) throws {
        self.db = db
        try Schema.migrate(db)
        try seedRootsIfNeeded()
        try reloadRoots()
    }

    convenience init() throws {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let url = directory.appendingPathComponent("JournalMate.sqlite")
        try self.init(db: SQLiteDatabase(path: url.path))
    }

    /// テストとプレビュー用のメモリ DB。
    static func inMemory() throws -> Store {
        try Store(db: SQLiteDatabase(path: ":memory:"))
    }

    /// ルートは Journal と PARA の 5 件だけ存在する。ユーザーは作れないし消せない。
    /// 新しい DB でも、ルートが後から増えた版からの移行でも、足りないものだけを足す。
    private func seedRootsIfNeeded() throws {
        try db.transaction { try insertMissingRoots() }
    }

    private func insertMissingRoots() throws {
        let existing = Set(try db.query("SELECT para FROM nodes WHERE parent_id IS NULL") {
            $0.string(0)
        })
        let now = Date()
        for (index, para) in Para.allCases.enumerated() where !existing.contains(para.rawValue) {
            try db.execute("""
                INSERT INTO nodes (id, parent_id, para, seg, code, path, title, depth, sort_order, created_at, updated_at)
                VALUES (?, NULL, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                """, [
                    .text(UUID().uuidString),
                    .text(para.rawValue),
                    .int(Int64(para.leadingDigit)),
                    .text(ParaCode.rootCode(para)),
                    .text("/\(para.title)"),
                    .text(para.title),
                    .int(Int64(index)),
                    .date(now),
                    .date(now),
                ])
        }
    }

    // MARK: - ノード読み出し

    func reloadRoots() throws {
        roots = try db.query(
            "\(Self.nodeColumns) FROM nodes WHERE parent_id IS NULL ORDER BY sort_order",
            decode: { Self.decodeNode($0) })
    }

    func children(of node: Node) throws -> [Node] {
        try db.query(
            "\(Self.nodeColumns) FROM nodes WHERE parent_id = ? ORDER BY seg, sort_order",
            [.text(node.id)], decode: { Self.decodeNode($0) })
    }

    func node(id: String) throws -> Node? {
        try db.query("\(Self.nodeColumns) FROM nodes WHERE id = ?",
                     [.text(id)], decode: { Self.decodeNode($0) }).first
    }

    /// `code` の前方一致で部分木をまとめて取る。AI に文脈を渡すときの主経路。
    func subtree(codePrefix: String) throws -> [Node] {
        try db.query(
            "\(Self.nodeColumns) FROM nodes WHERE code LIKE ? ORDER BY code",
            [.text(codePrefix + "%")], decode: { Self.decodeNode($0) })
    }

    /// 全ノードをフラットに。AI へのツリー提示や移動先ピッカーで使う。
    func allNodes() throws -> [Node] {
        try db.query("\(Self.nodeColumns) FROM nodes ORDER BY code", decode: { Self.decodeNode($0) })
    }

    // MARK: - ノード書き込み

    @discardableResult
    func createFolder(under parent: Node, title: String, seg: Int? = nil) throws -> Node {
        let siblings = try children(of: parent)
        let resolvedSeg = seg ?? ParaCode.nextSeg(usedBy: siblings)
        let now = Date()
        let node = Node(
            id: UUID().uuidString,
            parentID: parent.id,
            para: parent.para,
            seg: resolvedSeg,
            code: ParaCode.compose(parentCode: parent.code, para: parent.para, seg: resolvedSeg),
            path: ParaCode.compose(parentPath: parent.path, para: parent.para, title: title),
            title: title,
            depth: parent.depth + 1,
            sortOrder: siblings.count,
            createdAt: now,
            updatedAt: now)

        try db.execute("""
            INSERT INTO nodes (id, parent_id, para, seg, code, path, title, depth, sort_order, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .text(node.id), .text(node.parentID!), .text(node.para.rawValue),
                .int(Int64(node.seg)), .text(node.code), .text(node.path), .text(node.title),
                .int(Int64(node.depth)), .int(Int64(node.sortOrder)),
                .date(node.createdAt), .date(node.updatedAt),
            ])
        return node
    }

    func rename(_ node: Node, to title: String) throws {
        try db.transaction {
            try db.execute("UPDATE nodes SET title = ?, updated_at = ? WHERE id = ?",
                           [.text(title), .date(Date()), .text(node.id)])
            var renamed = node
            renamed.title = title
            try recomputeSubtree(of: renamed)
        }
    }

    /// 親を付け替える。PARA をまたぐ移動もここ。
    /// 本文（原本）は一切触らず、code と path だけを引き直す ＝ 非破壊の再分類。
    func move(_ node: Node, under newParent: Node) throws {
        guard node.parentID != nil else { return }           // PARA ルートは動かさない
        guard !isDescendant(newParent, of: node) else { return }  // 自分の子には入れない

        try db.transaction {
            let siblings = try children(of: newParent)
            let seg = ParaCode.nextSeg(usedBy: siblings)
            try db.execute("""
                UPDATE nodes SET parent_id = ?, para = ?, seg = ?, depth = ?, updated_at = ? WHERE id = ?
                """, [
                    .text(newParent.id), .text(newParent.para.rawValue), .int(Int64(seg)),
                    .int(Int64(newParent.depth + 1)), .date(Date()), .text(node.id),
                ])
            guard let moved = try self.node(id: node.id) else { return }
            try recomputeSubtree(of: moved)
        }
    }

    func delete(_ node: Node) throws {
        guard node.parentID != nil else { return }  // PARA ルートは消せない
        try db.execute("DELETE FROM nodes WHERE id = ?", [.text(node.id)])
    }

    /// 自分とその子孫の code / path を親から引き直す。
    /// ノートのファイル名も code を含むので一緒に振り直す。
    private func recomputeSubtree(of node: Node) throws {
        let parent = try node.parentID.flatMap { try self.node(id: $0) }
        var updated = node
        updated.code = ParaCode.compose(parentCode: parent?.code, para: node.para, seg: node.seg)
        updated.path = ParaCode.compose(parentPath: parent?.path, para: node.para, title: node.title)

        try db.execute("UPDATE nodes SET code = ?, path = ?, para = ? WHERE id = ?",
                       [.text(updated.code), .text(updated.path),
                        .text(updated.para.rawValue), .text(updated.id)])
        try renameFiles(in: updated)

        for child in try children(of: updated) {
            var next = child
            next.para = updated.para
            next.depth = updated.depth + 1
            try db.execute("UPDATE nodes SET para = ?, depth = ? WHERE id = ?",
                           [.text(next.para.rawValue), .int(Int64(next.depth)), .text(next.id)])
            try recomputeSubtree(of: next)
        }
    }

    private func renameFiles(in node: Node) throws {
        for note in try notes(in: node, layer: nil) {
            let filename = ParaCode.filename(
                code: node.code, layer: note.layer,
                title: note.title, occurredAt: note.occurredAt)
            try db.execute("UPDATE notes SET filename = ? WHERE id = ?",
                           [.text(filename), .text(note.id)])
        }
    }

    private func isDescendant(_ candidate: Node, of ancestor: Node) -> Bool {
        candidate.id == ancestor.id || candidate.path.hasPrefix(ancestor.path + "/")
    }

    // MARK: - ノート読み出し

    func notes(in node: Node, layer: Layer?) throws -> [Note] {
        if let layer {
            return try db.query("""
                \(Self.noteColumns) FROM notes
                WHERE node_id = ? AND layer = ? AND deleted_at IS NULL
                ORDER BY occurred_at DESC
                """, [.text(node.id), .text(layer.rawValue)], decode: Self.decodeNote)
        }
        return try db.query("""
            \(Self.noteColumns) FROM notes WHERE node_id = ? AND deleted_at IS NULL
            ORDER BY occurred_at DESC
            """, [.text(node.id)], decode: Self.decodeNote)
    }

    /// カレンダーで日付を選んだときの一覧。所属ノードを添えて PARA タグを出せるようにする。
    /// `codePrefixes` を渡すと、その部分木のノートだけに絞る（空なら絞り込まない）。
    func notes(on date: Date, codePrefixes: [String] = []) throws -> [NoteWithNode] {
        let filter = Self.codeFilter(codePrefixes)
        return try db.query("""
            \(Self.joinedColumns)
            FROM notes n JOIN nodes d ON d.id = n.node_id
            WHERE n.day_key = ? AND n.deleted_at IS NULL\(filter.sql)
            ORDER BY n.occurred_at
            """, [.text(Format.dayKey(for: date))] + filter.params, decode: Self.decodeJoined)
    }

    /// カレンダーの装飾用。日付ごとに「件数」と「最も多い PARA」を返す。
    /// 絞り込みは `notes(on:codePrefixes:)` と同じ意味。両者は必ず同じ値で呼ぶ
    /// —— ドットが付いている日を開いたら空だった、という食い違いを避けるため。
    func dayMarkers(from start: Date, to end: Date,
                    codePrefixes: [String] = []) throws -> [String: (count: Int, para: Para)] {
        let filter = Self.codeFilter(codePrefixes)
        let rows = try db.query("""
            SELECT n.day_key, d.para, COUNT(*) AS c
            FROM notes n JOIN nodes d ON d.id = n.node_id
            WHERE n.deleted_at IS NULL AND n.occurred_at BETWEEN ? AND ?\(filter.sql)
            GROUP BY n.day_key, d.para
            """, [.date(start), .date(end)] + filter.params) {
                ($0.string(0), Para(rawValue: $0.string(1)) ?? .areas, Int($0.int(2)))
            }

        var markers: [String: (count: Int, para: Para)] = [:]
        var dominant: [String: Int] = [:]
        for (day, para, count) in rows {
            let total = (markers[day]?.count ?? 0) + count
            if count > (dominant[day] ?? 0) {
                dominant[day] = count
                markers[day] = (total, para)
            } else {
                markers[day] = (total, markers[day]?.para ?? para)
            }
        }
        return markers
    }

    /// 削除していない記録すべて。過去のジャーナルを探す道具（`JournalRecall`）が呼ばれるたびに引く。
    /// 索引を別に作らず、その時点の中身をそのまま探させる。
    func liveNotes() throws -> [NoteWithNode] {
        try db.query("""
            \(Self.joinedColumns)
            FROM notes n JOIN nodes d ON d.id = n.node_id
            WHERE n.deleted_at IS NULL
            ORDER BY n.occurred_at DESC
            """, [], decode: Self.decodeJoined)
    }

    func recentNotes(limit: Int = 30) throws -> [NoteWithNode] {
        try db.query("""
            \(Self.joinedColumns)
            FROM notes n JOIN nodes d ON d.id = n.node_id
            WHERE n.deleted_at IS NULL
            ORDER BY n.occurred_at DESC LIMIT ?
            """, [.int(Int64(limit))], decode: Self.decodeJoined)
    }

    /// 全文検索。trigram トークナイザなので日本語 2 文字以下は LIKE に落とす。
    func search(_ text: String, limit: Int = 50) throws -> [NoteWithNode] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.count < 3 {
            return try db.query("""
                \(Self.joinedColumns)
                FROM notes n JOIN nodes d ON d.id = n.node_id
                WHERE n.deleted_at IS NULL AND (n.title LIKE ? OR n.body LIKE ?)
                ORDER BY n.occurred_at DESC LIMIT ?
                """, [.text("%\(trimmed)%"), .text("%\(trimmed)%"), .int(Int64(limit))],
                decode: Self.decodeJoined)
        }

        // trigram の MATCH は演算子を解釈するので、引用してリテラル扱いにする。
        let quoted = "\"" + trimmed.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return try db.query("""
            \(Self.joinedColumns)
            FROM notes_fts f
            JOIN notes n ON n.rowid = f.rowid
            JOIN nodes d ON d.id = n.node_id
            WHERE notes_fts MATCH ? AND n.deleted_at IS NULL
            ORDER BY rank LIMIT ?
            """, [.text(quoted), .int(Int64(limit))], decode: Self.decodeJoined)
    }

    // MARK: - ノート書き込み

    @discardableResult
    func createNote(in node: Node, layer: Layer, title: String, body: String,
                    occurredAt: Date = Date(), sourceURL: String? = nil) throws -> Note {
        let now = Date()
        let note = Note(
            id: UUID().uuidString,
            nodeID: node.id,
            layer: layer,
            filename: ParaCode.filename(code: node.code, layer: layer,
                                        title: title, occurredAt: occurredAt),
            title: title,
            body: body,
            sourceURL: sourceURL,
            occurredAt: occurredAt,
            dayKey: Format.dayKey(for: occurredAt),
            createdAt: now,
            updatedAt: now)

        try db.execute("""
            INSERT INTO notes (id, node_id, layer, filename, title, body, source_url,
                               occurred_at, day_key, created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            """, [
                .text(note.id), .text(note.nodeID), .text(note.layer.rawValue),
                .text(note.filename), .text(note.title), .text(note.body),
                .text(optional: note.sourceURL), .date(note.occurredAt), .text(note.dayKey),
                .date(note.createdAt), .date(note.updatedAt),
            ])
        return note
    }

    func updateNote(_ note: Note, title: String, body: String) throws {
        try db.execute("UPDATE notes SET title = ?, body = ?, updated_at = ? WHERE id = ?",
                       [.text(title), .text(body), .date(Date()), .text(note.id)])
    }

    /// ノートを別のノードへ移す。分類のやり直しはここを通る。
    /// 本文と occurred_at は触らない（カレンダー上の位置は動かさない）。
    /// 引き直すのは node_id と layer と、そこから導かれるファイル名だけ。
    func move(_ note: Note, to node: Node, layer: Layer? = nil) throws {
        let resolvedLayer = layer ?? note.layer
        let filename = ParaCode.filename(code: node.code, layer: resolvedLayer,
                                         title: note.title, occurredAt: note.occurredAt)
        try db.execute("""
            UPDATE notes SET node_id = ?, layer = ?, filename = ?, updated_at = ? WHERE id = ?
            """, [.text(node.id), .text(resolvedLayer.rawValue), .text(filename),
                   .date(Date()), .text(note.id)])
    }

    func note(id: String) throws -> Note? {
        try db.query("\(Self.noteColumns) FROM notes WHERE id = ? AND deleted_at IS NULL",
                     [.text(id)], decode: Self.decodeNote).first
    }

    /// ソフト削除。実削除は `purgeDeleted` がまとめて行う。
    func deleteNote(_ note: Note) throws {
        try db.execute("UPDATE notes SET deleted_at = ? WHERE id = ?",
                       [.date(Date()), .text(note.id)])
    }

    // MARK: - チャット

    func messages(sessionID: String) throws -> [Message] {
        try db.query("""
            SELECT id, session_id, role, content, note_id, created_at FROM messages
            WHERE session_id = ? ORDER BY created_at, rowid
            """, [.text(sessionID)]) {
                Message(id: $0.string(0), sessionID: $0.string(1),
                        role: Message.Role(rawValue: $0.string(2)) ?? .user,
                        content: $0.string(3), noteID: $0.stringOrNil(4),
                        createdAt: Date(timeIntervalSince1970: TimeInterval($0.int(5))))
            }
    }

    @discardableResult
    func appendMessage(sessionID: String, role: Message.Role,
                       content: String, noteID: String? = nil) throws -> Message {
        let message = Message(id: UUID().uuidString, sessionID: sessionID, role: role,
                              content: content, noteID: noteID, createdAt: Date())
        try db.execute("""
            INSERT INTO messages (id, session_id, role, content, note_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, [
                .text(message.id), .text(message.sessionID), .text(message.role.rawValue),
                .text(message.content), .text(optional: message.noteID), .date(message.createdAt),
            ])
        return message
    }

    func linkMessage(_ messageID: String, toNote noteID: String) throws {
        try db.execute("UPDATE messages SET note_id = ? WHERE id = ?",
                       [.text(noteID), .text(messageID)])
    }

    /// 過去の対話の一覧。新しく話した順。
    func chatSessions() throws -> [ChatSession] {
        try db.query("""
            SELECT m.session_id, MIN(m.created_at), MAX(m.created_at),
                   (SELECT f.content FROM messages f
                    WHERE f.session_id = m.session_id AND f.role = 'user'
                    ORDER BY f.created_at, f.rowid LIMIT 1)
            FROM messages m
            GROUP BY m.session_id
            ORDER BY MAX(m.created_at) DESC
            """) {
                ChatSession(id: $0.string(0),
                            title: $0.stringOrNil(3) ?? "",
                            startedAt: Date(timeIntervalSince1970: TimeInterval($0.int(1))),
                            updatedAt: Date(timeIntervalSince1970: TimeInterval($0.int(2))))
            }
    }

    /// 対話を 1 本消す。そこから作ったジャーナルは残る。
    func deleteChatSession(id: String) throws {
        try db.execute("DELETE FROM messages WHERE session_id = ?", [.text(id)])
    }

    // MARK: - 無料枠

    /// 今月すでに使った回数。月が変われば行が別になるので、自動的に 0 から数え直す。
    func usedThisMonth(_ feature: ProFeature, on date: Date = Date()) throws -> Int {
        try db.query("SELECT count FROM feature_usage WHERE feature = ? AND period = ?",
                     [.text(feature.rawValue), .text(Usage.period(for: date))]) {
            Int($0.int(0))
        }.first ?? 0
    }

    /// 1 回ぶん消費する。**AI の呼び出しが成功したときだけ**呼ぶこと
    /// （失敗した通信で無料枠を減らさない）。戻り値は消費後の回数。
    @discardableResult
    func consume(_ feature: ProFeature, on date: Date = Date()) throws -> Int {
        try db.execute("""
            INSERT INTO feature_usage (feature, period, count) VALUES (?, ?, 1)
            ON CONFLICT(feature, period) DO UPDATE SET count = count + 1
            """, [.text(feature.rawValue), .text(Usage.period(for: date))])
        return try usedThisMonth(feature, on: date)
    }

    // MARK: - トークンの上限

    /// 今日ぶんの消費。日をまたげば行が別になるので、自動的に 0 から数え直す。
    func tokenUsage(on date: Date = Date()) throws -> TokenUsage {
        try db.query("SELECT input, output, cache_read FROM token_usage WHERE day = ?",
                     [.text(Format.dayKey(for: date))]) {
            TokenUsage(input: Int($0.int(0)), output: Int($0.int(1)), cacheRead: Int($0.int(2)))
        }.first ?? TokenUsage()
    }

    /// 応答の `usage` をそのまま積む。呼び出しが失敗しても、
    /// **すでに生成されたぶんは実際に課金されている**ので、受け取れた数字は必ず記録する。
    func record(_ usage: TokenUsage, on date: Date = Date()) throws {
        guard !usage.isEmpty else { return }
        try db.execute("""
            INSERT INTO token_usage (day, input, output, cache_read, requests, updated_at)
            VALUES (?, ?, ?, ?, 1, ?)
            ON CONFLICT(day) DO UPDATE SET
              input = input + excluded.input,
              output = output + excluded.output,
              cache_read = cache_read + excluded.cache_read,
              requests = requests + 1,
              updated_at = excluded.updated_at
            """, [.text(Format.dayKey(for: date)), .int(Int64(usage.input)),
                   .int(Int64(usage.output)), .int(Int64(usage.cacheRead)), .date(Date())])
    }

    /// サーバが数えた回数で**上書き**する（足さない）。
    /// 正はゲートウェイ側にあるので、食い違ったらこちらを合わせる
    /// （アプリを入れ直して 0 に戻った表示が、サーバの数字に戻る）。
    func syncUsage(_ feature: ProFeature, used: Int, on date: Date = Date()) throws {
        try db.execute("""
            INSERT INTO feature_usage (feature, period, count) VALUES (?, ?, ?)
            ON CONFLICT(feature, period) DO UPDATE SET count = excluded.count
            """, [.text(feature.rawValue), .text(Usage.period(for: date)), .int(Int64(max(0, used)))])
    }

    /// 今日の残量。上限に当たったかどうかの判断はこれだけを見る。
    func dailyBudget(on date: Date = Date(), limit: Int = TokenBudget.daily) throws -> DailyBudget {
        DailyBudget(used: try tokenUsage(on: date).weighted, limit: limit)
    }

    /// 今日の呼び出し回数。設定画面に出す。
    func requestCount(on date: Date = Date()) throws -> Int {
        try db.query("SELECT requests FROM token_usage WHERE day = ?",
                     [.text(Format.dayKey(for: date))]) { Int($0.int(0)) }.first ?? 0
    }

    // MARK: - 取り込み

    /// 取り込み済みの原本パス。二重取り込みを弾くためのキー。
    /// 削除済みは外す（消したメモをもう一度入れ直せるように）。
    func importedSourceURLs() throws -> Set<String> {
        Set(try db.query("SELECT source_url FROM notes WHERE source_url IS NOT NULL AND deleted_at IS NULL") {
            $0.string(0)
        })
    }

    /// 複数の書き込みを 1 トランザクションにまとめる。数百件の取り込みで効く。
    func batch(_ body: () throws -> Void) throws {
        try db.transaction(body)
    }

    // MARK: - バックアップと復元

    /// DB の写しを 1 ファイルに書く。Vault の書き出しに同梱して、再インストール後の復元に使う。
    /// `VACUUM INTO` は WAL の中身も含めた整合の取れた写しを作る。
    ///
    /// 対話の履歴は入れない。端末の中だけに置く中間生成物で、残したいものはジャーナルにする。
    /// 消した後にもう一度 VACUUM して、空きページに本文が残らないようにする。
    func writeBackup(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try db.execute("VACUUM INTO ?", [.text(url.path)])
        let copy = try SQLiteDatabase(path: url.path)
        try copy.execute("DELETE FROM messages")
        // 書き出すのは 1 ファイルだけなので、-wal を残さないジャーナル方式に戻す。
        try copy.execute("PRAGMA journal_mode = DELETE")
        try copy.execute("VACUUM")
    }

    /// バックアップの中身で、ノード・ノートを**丸ごと置き換える**。
    /// 利用量の記録（無料枠・トークン）と対話の履歴はこの端末のものを残す
    /// （履歴はバックアップに入れない。古い版のバックアップに入っていても戻さない）。
    ///
    /// `url` は書き換えてよい一時コピーを渡すこと（古い版なら先にマイグレーションするため）。
    /// 失敗したら何も変わらない。
    func restore(fromBackup url: URL) throws -> Int {
        do {
            let backup = try SQLiteDatabase(path: url.path)
            let version = try backup.query("PRAGMA user_version") { Int($0.int(0)) }.first ?? 0
            guard version >= 1 else { throw BackupError.notABackup }
            guard version <= Schema.latestVersion else { throw BackupError.newerVersion }
            try Schema.migrate(backup)
        }

        try db.execute("ATTACH DATABASE ? AS backup", [.text(url.path)])
        defer { try? db.execute("DETACH DATABASE backup") }

        try db.transaction {
            // 対話は残すが、置き換わるノートへの繋がりだけは外す。
            try db.execute("UPDATE messages SET note_id = NULL WHERE note_id IS NOT NULL")
            try db.execute("DELETE FROM notes")
            try db.execute("DELETE FROM nodes")
            // 列の並びは同じスキーマから作っているので揃っている。
            try db.execute("INSERT INTO nodes SELECT * FROM backup.nodes ORDER BY depth")
            try db.execute("INSERT INTO notes SELECT * FROM backup.notes")
            let roots = try db.query("SELECT COUNT(*) FROM nodes WHERE parent_id IS NULL") {
                Int($0.int(0))
            }.first ?? 0
            guard roots > 0, roots <= Para.allCases.count else { throw BackupError.notABackup }
            // Journal が無い頃のバックアップにはそのルートが無いので補う。
            try insertMissingRoots()
        }
        try reloadRoots()
        return try db.query("SELECT COUNT(*) FROM notes WHERE deleted_at IS NULL") {
            Int($0.int(0))
        }.first ?? 0
    }

    enum BackupError: Error, LocalizedError {
        case notABackup
        case newerVersion
        case missing

        var errorDescription: String? {
            switch self {
            case .notABackup:
                return String(localized: "This isn't a JournalMate backup.")
            case .newerVersion:
                return String(localized: "This backup was made with a newer version of JournalMate. Update the app and try again.")
            case .missing:
                return String(localized: "No restore data was found. Choose a .zip exported with “Export Backup” in JournalMate.")
            }
        }
    }

    // MARK: - 掃除

    /// 起動時の定期掃除。生のチャットログは中間生成物なので溜めない。
    func purge(chatRetentionDays: Int = 90, trashRetentionDays: Int = 30) throws {
        let chatCutoff = Date().addingTimeInterval(-Double(chatRetentionDays) * 86_400)
        let trashCutoff = Date().addingTimeInterval(-Double(trashRetentionDays) * 86_400)
        try db.execute("DELETE FROM messages WHERE created_at < ? AND note_id IS NULL",
                       [.date(chatCutoff)])
        try db.execute("DELETE FROM notes WHERE deleted_at IS NOT NULL AND deleted_at < ?",
                       [.date(trashCutoff)])
    }

    // MARK: - 行のデコード

    private static let nodeColumns =
        "SELECT id, parent_id, para, seg, code, path, title, depth, sort_order, created_at, updated_at"

    private static let noteColumns =
        "SELECT id, node_id, layer, filename, title, body, source_url, occurred_at, day_key, created_at, updated_at"

    private static let joinedColumns = """
        SELECT n.id, n.node_id, n.layer, n.filename, n.title, n.body, n.source_url,
               n.occurred_at, n.day_key, n.created_at, n.updated_at,
               d.id, d.parent_id, d.para, d.seg, d.code, d.path, d.title, d.depth,
               d.sort_order, d.created_at, d.updated_at
        """

    /// `code` の前方一致を OR で束ねた WHERE 断片。空なら断片も無し＝全件。
    /// code は数字だけなので LIKE のワイルドカード（% _）が混ざる余地はない。
    private static func codeFilter(_ prefixes: [String]) -> (sql: String, params: [SQLiteDatabase.Value]) {
        guard !prefixes.isEmpty else { return ("", []) }
        let clause = prefixes.map { _ in "d.code LIKE ?" }.joined(separator: " OR ")
        return (" AND (\(clause))", prefixes.map { .text($0 + "%") })
    }

    private static func decodeNode(_ row: SQLiteDatabase.Row, offset: Int32 = 0) -> Node {
        Node(id: row.string(offset),
             parentID: row.stringOrNil(offset + 1),
             para: Para(rawValue: row.string(offset + 2)) ?? .areas,
             seg: Int(row.int(offset + 3)),
             code: row.string(offset + 4),
             path: row.string(offset + 5),
             title: row.string(offset + 6),
             depth: Int(row.int(offset + 7)),
             sortOrder: Int(row.int(offset + 8)),
             createdAt: Date(timeIntervalSince1970: TimeInterval(row.int(offset + 9))),
             updatedAt: Date(timeIntervalSince1970: TimeInterval(row.int(offset + 10))))
    }

    private static func decodeNote(_ row: SQLiteDatabase.Row) -> Note {
        Note(id: row.string(0),
             nodeID: row.string(1),
             layer: Layer(rawValue: row.string(2)) ?? .journal,
             filename: row.string(3),
             title: row.string(4),
             body: row.string(5),
             sourceURL: row.stringOrNil(6),
             occurredAt: Date(timeIntervalSince1970: TimeInterval(row.int(7))),
             dayKey: row.string(8),
             createdAt: Date(timeIntervalSince1970: TimeInterval(row.int(9))),
             updatedAt: Date(timeIntervalSince1970: TimeInterval(row.int(10))))
    }

    private static func decodeJoined(_ row: SQLiteDatabase.Row) -> NoteWithNode {
        NoteWithNode(note: decodeNote(row), node: decodeNode(row, offset: 11))
    }
}
