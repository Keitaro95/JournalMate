import SwiftUI

/// AI の提案を確定させる前の確認画面。
/// ここを挟むことで、AI が勝手に書いた記録が溜まらないようにする。
struct JournalDraftSheet: View {

    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft: JournalDraft
    @State private var nodes: [Node] = []
    /// 空文字 = 新規パスを作る
    @State private var selectedCode: String

    private let onCommit: (JournalDraft) -> Void

    init(draft: JournalDraft, onCommit: @escaping (JournalDraft) -> Void) {
        _draft = State(initialValue: draft)
        _selectedCode = State(initialValue: draft.nodeCode)
        self.onCommit = onCommit
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $draft.title)
                }

                Section("Body (Markdown)") {
                    MultilineTextInput(
                        placeholder: "",
                        text: $draft.body,
                        minHeight: 180)
                }

                Section("PARA") {
                    Picker("Category", selection: $draft.para) {
                        ForEach(Para.allCases) { para in
                            Label("\(para.title) (\(para.subtitle))", systemImage: para.symbol)
                                .tag(para)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    // PARA を変えたら、別の PARA のフォルダを選んだままにしない
                    // （見た目と違う PARA に保存されてしまうため）。
                    .onChange(of: draft.para) {
                        if !candidates.contains(where: { $0.code == selectedCode }) {
                            selectedCode = ""
                        }
                    }
                }

                Section {
                    Picker("Layer", selection: $draft.layer) {
                        ForEach(Layer.allCases) { layer in
                            Text(layer.title).tag(layer)
                        }
                    }
                } header: {
                    Text("Type")
                } footer: {
                    Text(draft.layer.summary)
                }

                Section {
                    Picker("Destination", selection: $selectedCode) {
                        Text("Create New").tag("")
                        ForEach(candidates) { node in
                            Text("\(node.code)  \(node.path)").tag(node.code)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    if selectedCode.isEmpty {
                        TextField("New path (e.g. Life/Travel/Insurance)", text: $draft.suggestedPath)
                    }
                } header: {
                    Text("Folder")
                } footer: {
                    Text(destinationDescription)
                }
            }
            .navigationTitle("Save as Journal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.nodeCode = selectedCode
                        // 保存先のフォルダがあれば、PARA はフォルダ側を正とする。
                        if let node = nodes.first(where: { $0.code == selectedCode }) {
                            draft.para = node.para
                        }
                        onCommit(draft)
                        dismiss()
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task { nodes = (try? store.allNodes()) ?? [] }
        }
    }

    /// PARA が合致するノードだけを候補にする。ルート自身は除く（Journal のルートは置き場なので残す）。
    private var candidates: [Node] {
        nodes.filter { $0.para == draft.para && ($0.parentID != nil || $0.para.acceptsNotesAtRoot) }
    }

    private var destinationDescription: String {
        if let node = nodes.first(where: { $0.code == selectedCode }) {
            let name = ParaCode.filename(code: node.code, layer: draft.layer,
                                         title: draft.title, occurredAt: draft.occurredAt)
            return "\(node.path)/\(draft.layer.directoryName)/\(name)"
        }
        if draft.suggestedPath.isEmpty, draft.para.acceptsNotesAtRoot {
            return "/\(draft.para.title)/\(draft.layer.directoryName)/"
        }
        let path = draft.suggestedPath.isEmpty ? MemoImporter.inboxTitle : draft.suggestedPath
        return String(localized: "Will be created in /\(draft.para.title)/\(path)/\(draft.layer.directoryName)/")
    }
}
