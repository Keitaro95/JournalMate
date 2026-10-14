import SwiftUI

/// 自分の手で書くジャーナル。Tree の「New Journal」と同じ書き心地で書き、
/// 置く場所は Tree のフォルダの中から自分で選ぶ。AI は使わないので、プランが無くてもずっと書ける。
/// 置く場所を選ばなければ Journal のルート（/Journal/journal/）に置く。
struct JournalScreen: View {

    @Environment(Store.self) private var store

    /// 最後に選んだ保存先。毎回同じ場所に書く人が多いので、次も最初からそこを選んでおく。
    @AppStorage("journalDestinationCode") private var destinationCode = ""

    @State private var title = ""
    @State private var body_ = ""
    @State private var destination: Node?
    @State private var isPickingFolder = false
    /// 保存したフォルダの名前。「{フォルダ名}に記録しました」に使う。
    @State private var savedFolder: String?
    @State private var errorMessage: String?

    private var canSave: Bool {
        !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 書き始めたのに保存先を選んでいない。黙って Journal に置くのではなく、置き場所を先に伝える。
    private var needsDestinationHint: Bool {
        destination == nil && !(title + body_).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    destinationRow
                    if needsDestinationHint {
                        Label("Choose where to save (a subfolder). If you don't, it's saved to Journal / journal.",
                              systemImage: "info.circle")
                            .appFont(.caption1)
                            .foregroundStyle(.secondary)
                    }
                    TextField("Title", text: $title)
                        .appFont(.title2, weight: .semibold)
                        .textFieldStyle(.plain)
                    Divider()
                    MultilineTextInput(
                        placeholder: String(localized: "What happened today?"),
                        text: $body_,
                        minHeight: 320)
                }
                .padding()
            }
            .navigationTitle(Format.dayKey(for: Date()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $isPickingFolder) {
                FolderPickerSheet { node in
                    destination = node
                    destinationCode = node.code
                }
            }
            .alert(savedFolder.map { String(localized: "Saved to \($0)") } ?? "",
                   isPresented: .constant(savedFolder != nil)) {
                Button("OK") { savedFolder = nil }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear { restoreDestination() }
        }
    }

    // MARK: - 部品

    private var destinationRow: some View {
        Button {
            isPickingFolder = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(destination?.para.tint ?? .secondary)
                if let destination {
                    ParaTag(para: destination.para)
                    Text(verbatim: "\(destination.path)/\(Layer.journal.directoryName)/")
                        .appFont(.caption1, monospacedDigits: true)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text("Choose where to save")
                        .appFont(.subheadline)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .appFont(.caption1, weight: .semibold)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 動作

    /// 前回のフォルダがまだあればそれを選ぶ。消されていたら未選択に戻す。
    private func restoreDestination() {
        guard destination == nil, !destinationCode.isEmpty else { return }
        destination = try? store.node(code: destinationCode)
        if destination == nil { destinationCode = "" }
    }

    private func save() {
        let text = body_.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = title.trimmingCharacters(in: .whitespaces)
        // 見出しが空なら本文の書き出しを使う（チャットから自分の言葉で残すときと同じ）。
        let resolvedTitle = heading.isEmpty ? String(text.prefix(24)) : heading
        do {
            let target = try store.createJournal(in: destination, title: resolvedTitle, body: text).node
            title = ""
            body_ = ""
            savedFolder = target.parentID == nil ? target.para.displayTitle : target.title
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Tree のフォルダを辿って、ジャーナルを置く場所を選ぶ。
/// PARA の直下（ルート）には置かない。受け皿がぼやけるため、必ずどこかのフォルダを選ぶ。
/// Journal だけはルートがそのまま置き場。
struct FolderPickerSheet: View {

    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// 置く層。フッターのパス表示に使う。新しく書くときは journal、既存ノートを移すときはそのノートの層。
    var layer: Layer = .journal
    /// 既存のノートを移すために開いた。ボタンを「Move Here」にする（新しく書くときは「Save Here」）。
    var isMoving = false
    let onPick: (Node) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.roots) { root in
                        NavigationLink {
                            FolderPickerLevel(node: root, layer: layer, isMoving: isMoving) { pick($0) }
                        } label: {
                            Label {
                                Text(root.para.displayTitle)
                            } icon: {
                                Image(systemName: root.para.symbol)
                                    .foregroundStyle(root.para.tint)
                            }
                        }
                    }
                } footer: {
                    if isMoving {
                        Text("Open a folder, then tap \"Move Here\".")
                    } else {
                        Text("Open a folder, then tap \"Save Here\".")
                    }
                }
            }
            .navigationTitle("Choose Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func pick(_ node: Node) {
        onPick(node)
        dismiss()
    }
}

/// フォルダ選択の 1 階層。サブフォルダへ降りるか、ここに決める。
private struct FolderPickerLevel: View {

    @Environment(Store.self) private var store

    let node: Node
    let layer: Layer
    let isMoving: Bool
    let onPick: (Node) -> Void

    @State private var children: [Node] = []
    @State private var isAddingFolder = false
    @State private var newFolderTitle = ""
    /// 作ったばかりのフォルダ。そのまま中へ進んで「Save Here」できるようにする。
    @State private var createdFolder: Node?
    @State private var errorMessage: String?

    private var isRoot: Bool { node.parentID == nil }
    private var canSaveHere: Bool { !isRoot || node.para.acceptsNotesAtRoot }

    var body: some View {
        List {
            if canSaveHere {
                Section {
                    Button {
                        onPick(node)
                    } label: {
                        Label(isMoving ? LocalizedStringKey("Move Here") : "Save Here", systemImage: "checkmark.circle.fill")
                    }
                } footer: {
                    Text(verbatim: "\(node.path)/\(layer.directoryName)/")
                        .appFont(.caption2, monospacedDigits: true)
                }
            }
            // PARA の 4 つは直下に置けない。サブフォルダが無いと置き場が無いので、作る入口を先頭に出す。
            if !canSaveHere, children.isEmpty {
                Section {
                    Button("Add Subfolder", systemImage: "folder.badge.plus") {
                        isAddingFolder = true
                    }
                } footer: {
                    Text("Create a subfolder to save here.")
                }
            }
            Section {
                if children.isEmpty {
                    Text("No subfolders")
                        .foregroundStyle(.secondary)
                }
                ForEach(children) { child in
                    NavigationLink {
                        FolderPickerLevel(node: child, layer: layer, isMoving: isMoving, onPick: onPick)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .foregroundStyle(child.para.tint)
                            Text(child.title)
                        }
                    }
                }

                if canSaveHere || !children.isEmpty {
                    Button("Add Subfolder", systemImage: "folder.badge.plus") {
                        isAddingFolder = true
                    }
                }
            } header: {
                Text("Folders")
            } footer: {
                if !canSaveHere, !children.isEmpty {
                    Text("Journals go inside a folder. Open one, or add a subfolder.")
                }
            }
        }
        .navigationTitle(isRoot ? node.para.displayTitle : node.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $createdFolder) { folder in
            FolderPickerLevel(node: folder, layer: layer, isMoving: isMoving, onPick: onPick)
        }
        .alert("Add Subfolder", isPresented: $isAddingFolder) {
            TextField("Name (e.g. Travel)", text: $newFolderTitle)
            Button("Cancel", role: .cancel) { newFolderTitle = "" }
            Button("Add") { addFolder() }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { reload() }
    }

    private func reload() {
        children = (try? store.children(of: node)) ?? []
    }

    private func addFolder() {
        let title = newFolderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderTitle = ""
        guard !title.isEmpty else { return }
        do {
            // 番号は画面に出さないので、いつも空き番号を自動で振る。
            let folder = try store.createFolder(under: node, title: title)
            reload()
            createdFolder = folder
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
