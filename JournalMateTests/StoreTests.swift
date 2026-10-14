import Foundation
import Testing
@testable import JournalMate

/// データ層を実機・シミュレータの上で確かめる。
/// `Verification/` は macOS で同じ層を動かすが、こちらは iOS の SQLite / ファイル App の上で動かす。
@MainActor
struct StoreTests {

    private let store: Store
    private let when = Format.fileTimestamp.date(from: "202609191330")!

    init() throws {
        store = try Store.inMemory()
    }

    // MARK: - PARA

    @Test func rootsAreJournalPlusPARA() {
        #expect(store.roots.map(\.para) == Para.allCases)
        #expect(store.roots.map(\.code) == ["1", "2", "3", "4", "5"])
    }

    @Test func rootsCannotBeDeletedOrMoved() throws {
        let areas = try #require(store.root(for: .areas))
        let projects = try #require(store.root(for: .projects))
        try store.delete(areas)
        try store.move(areas, under: projects)
        try store.reloadRoots()
        #expect(store.roots.count == 5)
        #expect(store.root(for: .areas)?.code == "3")
    }

    // MARK: - 階層とコード

    @Test func codesFollowTheHierarchy() throws {
        let areas = try #require(store.root(for: .areas))
        let life = try store.createFolder(under: areas, title: "生活", seg: 1)
        let travel = try store.createFolder(under: life, title: "旅行", seg: 5)
        let insurance = try store.createFolder(under: travel, title: "保険", seg: 2)
        #expect(insurance.code == "3152")
        #expect(insurance.path == "/Areas/生活/旅行/保険")

        let hobby = try store.createFolder(under: life, title: "趣味")
        #expect(hobby.code == "311", "空いている最小の番号を振る")
    }

    @Test func movingAcrossPARARecomputesCodesAndFilenames() throws {
        let areas = try #require(store.root(for: .areas))
        let projects = try #require(store.root(for: .projects))
        let work = try store.createFolder(under: areas, title: "仕事")
        let note = try store.createNote(in: work, layer: .journal, title: "会議",
                                        body: "長引いた", occurredAt: when)
        #expect(note.filename == "31_202609191330.md")

        try store.move(work, under: projects)
        let moved = try #require(try store.node(id: work.id))
        #expect(moved.para == .projects)
        #expect(moved.code == "21")
        #expect(moved.path == "/Projects/仕事")

        let reloaded = try #require(try store.note(id: note.id))
        #expect(reloaded.filename == "21_202609191330.md")
        #expect(reloaded.body == "長引いた", "移動しても本文は変わらない")
    }

    @Test func cannotMoveFolderIntoItsOwnChild() throws {
        let areas = try #require(store.root(for: .areas))
        let parent = try store.createFolder(under: areas, title: "親")
        let child = try store.createFolder(under: parent, title: "子")
        try store.move(parent, under: child)
        #expect(try store.node(id: parent.id)?.parentID == areas.id)
    }

    @Test func renameUpdatesDescendantPaths() throws {
        let areas = try #require(store.root(for: .areas))
        let life = try store.createFolder(under: areas, title: "生活")
        let travel = try store.createFolder(under: life, title: "旅行")
        try store.rename(life, to: "暮らし")
        #expect(try store.node(id: travel.id)?.path == "/Areas/暮らし/旅行")
    }

    @Test func ensureFolderIsIdempotent() throws {
        let first = try store.ensureFolder(para: .areas, components: ["仕事", "会議"])
        let second = try store.ensureFolder(para: .areas, components: ["仕事", "会議"])
        #expect(first.id == second.id)
        #expect(try store.subtree(codePrefix: "3").count == 3)  // Areas + 仕事 + 会議
    }

    // MARK: - ノート・カレンダー・検索

    @Test func notesShowUpOnTheirDay() throws {
        let journal = try #require(store.root(for: .journal))
        try store.createNote(in: journal, layer: .journal, title: "今日", body: "晴れ", occurredAt: when)

        let sameDay = try store.notes(on: when)
        #expect(sameDay.count == 1)
        #expect(sameDay.first?.node.para == .journal)
        #expect(try store.notes(on: when.addingTimeInterval(86_400)).isEmpty)

        let markers = try store.dayMarkers(from: when.addingTimeInterval(-86_400 * 7),
                                           to: when.addingTimeInterval(86_400 * 7))
        #expect(markers["2026-09-19"]?.count == 1)
    }

    @Test func journalWithoutDestinationGoesToJournalRoot() throws {
        let saved = try store.createJournal(in: nil, title: "行き先なし", body: "保存先を選ばずに書いた", occurredAt: when)
        #expect(saved.node.para == .journal)
        #expect(saved.node.parentID == nil, "Journal のルートに置く")
        #expect(saved.note.layer == .journal)

        // Calendar（その日の一覧）と Folders（全文検索・フォルダの中）で見つかる。
        #expect(try store.notes(on: when).map(\.note.id) == [saved.note.id])
        #expect(try store.search("保存先を選ばず").count == 1)
        #expect(try store.notes(in: saved.node, layer: .journal).map(\.id) == [saved.note.id])
    }

    @Test func journalWithDestinationGoesThere() throws {
        let areas = try #require(store.root(for: .areas))
        let folder = try store.createFolder(under: areas, title: "旅行")
        let saved = try store.createJournal(in: folder, title: "選んだ", body: "旅行のメモ", occurredAt: when)
        #expect(saved.node.id == folder.id)
    }

    @Test func movingANoteChangesOnlyItsFolder() throws {
        let saved = try store.createJournal(in: nil, title: "あとで移す", body: "最初は Journal に置いた", occurredAt: when)
        let projects = try #require(store.root(for: .projects))
        let folder = try store.createFolder(under: projects, title: "引っ越し")

        try store.move(saved.note, to: folder)
        let moved = try #require(try store.note(id: saved.note.id))
        #expect(moved.nodeID == folder.id)
        #expect(moved.layer == .journal, "層は変えない")
        #expect(moved.filename == ParaCode.filename(code: folder.code, layer: .journal,
                                                    title: saved.note.title, occurredAt: when),
                "ファイル名は新しいフォルダのコードから作り直す")
        #expect(moved.body == saved.note.body)
        #expect(moved.occurredAt == saved.note.occurredAt, "カレンダー上の位置は動かさない")

        // Folders では新しいフォルダにだけ出て、Calendar ではフォルダが新しくなる。
        #expect(try store.notes(in: saved.node, layer: .journal).isEmpty)
        #expect(try store.notes(in: folder, layer: .journal).map(\.id) == [saved.note.id])
        #expect(try store.notes(on: when).map(\.node.id) == [folder.id])
    }

    @Test func japaneseFullTextSearch() throws {
        let areas = try #require(store.root(for: .areas))
        let folder = try store.createFolder(under: areas, title: "保険")
        try store.createNote(in: folder, layer: .raw, title: "比較記事",
                             body: "クレジットカード付帯の海外旅行保険", occurredAt: when)
        #expect(try store.search("海外旅行").count == 1)
        #expect(try store.search("存在しない言葉").isEmpty)
    }

    @Test func deletedNotesDisappearFromViews() throws {
        let journal = try #require(store.root(for: .journal))
        let note = try store.createNote(in: journal, layer: .journal, title: "消す",
                                        body: "一時的なメモ", occurredAt: when)
        try store.deleteNote(note)
        #expect(try store.notes(on: when).isEmpty)
        #expect(try store.search("一時的").isEmpty)
    }

    @Test func updateNoteKeepsItsDate() throws {
        let journal = try #require(store.root(for: .journal))
        let note = try store.createNote(in: journal, layer: .journal, title: "前",
                                        body: "前の本文", occurredAt: when)
        try store.updateNote(note, title: "後", body: "後の本文")
        let updated = try #require(try store.note(id: note.id))
        #expect(updated.title == "後")
        #expect(updated.body == "後の本文")
        #expect(updated.occurredAt == note.occurredAt)
    }

    // MARK: - 会話

    @Test func chatMessagesRoundTrip() throws {
        try store.appendMessage(sessionID: "s1", role: .user, content: "こんにちは")
        try store.appendMessage(sessionID: "s1", role: .assistant, content: "今日はどうでしたか")
        let messages = try store.messages(sessionID: "s1")
        #expect(messages.map(\.role) == [.user, .assistant])
        try store.deleteChatSession(id: "s1")
        #expect(try store.messages(sessionID: "s1").isEmpty)
    }

    // MARK: - バックアップ

    @Test func backupExportAndRestoreRoundTrip() throws {
        let areas = try #require(store.root(for: .areas))
        let folder = try store.createFolder(under: areas, title: "生活")
        try store.createNote(in: folder, layer: .journal, title: "残す", body: "大事な記録", occurredAt: when)
        try store.appendMessage(sessionID: "s1", role: .user, content: "履歴は入れない")

        let zip = try VaultExporter.exportZip(from: store)
        #expect(FileManager.default.fileExists(atPath: zip.path))

        // 入れ直した想定の、まっさらな DB に戻す。
        let fresh = try Store.inMemory()
        let backup = try VaultExporter.extractBackup(from: zip)
        let restored = try fresh.restore(fromBackup: backup)
        #expect(restored == 1)
        #expect(try fresh.search("大事な記録").count == 1)
        #expect(try fresh.node(code: folder.code)?.path == "/Areas/生活")
        #expect(fresh.roots.count == 5)
    }

    @Test func restoringSomethingElseFailsWithoutChanges() throws {
        let journal = try #require(store.root(for: .journal))
        try store.createNote(in: journal, layer: .journal, title: "既存", body: "消えない", occurredAt: when)

        let bogus = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID()).sqlite")
        try Data("not a database".utf8).write(to: bogus)
        #expect(throws: (any Error).self) { try store.restore(fromBackup: bogus) }
        #expect(try store.search("消えない").count == 1)
    }

    @Test func markdownExportHasFrontmatter() throws {
        let areas = try #require(store.root(for: .areas))
        let folder = try store.createFolder(under: areas, title: "生活")
        let note = try store.createNote(in: folder, layer: .journal, title: "見出し",
                                        body: "本文", occurredAt: when)
        let markdown = VaultExporter.markdown(for: note, in: folder)
        #expect(markdown.hasPrefix("---\n"))
        #expect(markdown.contains("本文"))
    }
}
