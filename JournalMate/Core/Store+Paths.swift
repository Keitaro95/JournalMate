import Foundation

extension Store {

    func root(for para: Para) -> Node? {
        roots.first { $0.para == para }
    }

    func node(code: String) throws -> Node? {
        try allNodes().first { $0.code == code }
    }

    /// "生活/旅行/保険" のようなパスを、無ければ作りながらたどって最下層を返す。
    /// 既にあるフォルダは作り直さないので、AI の提案を何度流しても増殖しない。
    @discardableResult
    func ensureFolder(para: Para, components: [String]) throws -> Node {
        guard var current = root(for: para) else {
            throw NSError(domain: "JournalMate", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "The PARA root folder was not found"),
            ])
        }
        for component in components {
            let title = component.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            if let existing = try children(of: current).first(where: { $0.title == title }) {
                current = existing
            } else {
                current = try createFolder(under: current, title: title)
            }
        }
        return current
    }

    /// AI のジャーナル案を実際のノートとして確定させる。
    /// 配置先は「既存コード優先、無ければ提案パスを作る、それも無ければ PARA 直下の受け皿」。
    /// Journal はルートそのものが受け皿。
    @discardableResult
    func commit(_ draft: JournalDraft) throws -> NoteWithNode {
        let node: Node
        if !draft.nodeCode.isEmpty, let existing = try self.node(code: draft.nodeCode) {
            node = existing
        } else if !draft.suggestedPath.isEmpty {
            node = try ensureFolder(para: draft.para, components: draft.suggestedPath
                .split(separator: "/").map(String.init))
        } else if draft.para.acceptsNotesAtRoot {
            node = try ensureFolder(para: draft.para, components: [])
        } else {
            node = try ensureFolder(para: draft.para, components: [try inboxTitle(in: draft.para)])
        }

        let note = try createNote(in: node, layer: draft.layer, title: draft.title,
                                  body: draft.body, occurredAt: draft.occurredAt)
        return NoteWithNode(note: note, node: node)
    }
}

// MARK: - 受信箱

extension Store {

    /// 取り込んだメモの受け皿。まだ無ければ nil。
    func inboxNode() throws -> Node? {
        let paths = Set(MemoImporter.inboxTitles.map { "/\(MemoImporter.inboxPara.title)/\($0)" })
        return try allNodes().first { paths.contains($0.path) }
    }

    /// その PARA 直下の受信箱の名前。既にあればその名前をそのまま使い、
    /// 無ければ表示言語の名前にする（言語を切り替えても受信箱が 2 つにならないように）。
    func inboxTitle(in para: Para) throws -> String {
        guard let root = root(for: para) else { return MemoImporter.inboxTitle }
        return try children(of: root)
            .first { MemoImporter.inboxTitles.contains($0.title) }?.title
            ?? MemoImporter.inboxTitle
    }
}
