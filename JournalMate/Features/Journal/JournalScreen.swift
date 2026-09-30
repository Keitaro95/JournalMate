import SwiftUI

/// 自分の手で書くジャーナル。Tree の「New Journal」と同じ書き心地で書き、
/// 置く場所は Tree のフォルダの中から自分で選ぶ。AI は使わない。
struct JournalScreen: View {

    @Environment(Store.self) private var store
    @Environment(Entitlement.self) private var entitlement

    /// 最後に選んだ保存先。毎回同じ場所に書く人が多いので、次も最初からそこを選んでおく。
    @AppStorage("journalDestinationCode") private var destinationCode = ""

    @State private var title = ""
    @State private var body_ = ""
    @State private var destination: Node?
    @State private var isPickingFolder = false
    @State private var savedPath: String?
    @State private var errorMessage: String?

    private var canSave: Bool {
        destination != nil && !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    destinationRow
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
                // 無料プランでは触れた瞬間に Paywall。
                .proGate(.journalWrite)
            }
            .navigationTitle(Format.dayKey(for: Date()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(!canSave || !entitlement.isPro)
                }
            }
            .sheet(isPresented: $isPickingFolder) {
                FolderPickerSheet { node in
                    destination = node
                    destinationCode = node.code
                }
            }
            .alert("Saved", isPresented: .constant(savedPath != nil)) {
                Button("OK") { savedPath = nil }
            } message: {
                Text(savedPath ?? "")
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
        guard let destination else { return }
        let text = body_.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = title.trimmingCharacters(in: .whitespaces)
        // 見出しが空なら本文の書き出しを使う（チャットから自分の言葉で残すときと同じ）。
        let resolvedTitle = heading.isEmpty ? String(text.prefix(24)) : heading
        do {
            try store.createNote(in: destination, layer: .journal, title: resolvedTitle, body: text)
            title = ""
            body_ = ""
            savedPath = "\(destination.path)/\(Layer.journal.directoryName)/"
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

    let onPick: (Node) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.roots) { root in
                        NavigationLink {
                            FolderPickerLevel(node: root) { pick($0) }
                        } label: {
                            Label {
                                Text(root.para.title)
                            } icon: {
                                Image(systemName: root.para.symbol)
                                    .foregroundStyle(root.para.tint)
                            }
                        }
                    }
                } footer: {
                    Text("Open a folder, then tap \"Save Here\".")
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
    let onPick: (Node) -> Void

    @State private var children: [Node] = []
    @State private var isAddingFolder = false
    @State private var newFolderTitle = ""
    /// 空なら空き番号を自動で振る。Folders 画面の「Add Subfolder」と同じ。
    @State private var newFolderSeg = ""
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
                        Label("Save Here", systemImage: "checkmark.circle.fill")
                    }
                } footer: {
                    Text(verbatim: "\(node.path)/\(Layer.journal.directoryName)/")
                        .appFont(.caption2, monospacedDigits: true)
                }
            }
            Section {
                if children.isEmpty {
                    Text("No subfolders")
                        .foregroundStyle(.secondary)
                }
                ForEach(children) { child in
                    NavigationLink {
                        FolderPickerLevel(node: child, onPick: onPick)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .foregroundStyle(child.para.tint)
                            Text(child.title)
                            Spacer()
                            Text(child.code)
                                .appFont(.caption1, monospacedDigits: true)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Button("Add Subfolder", systemImage: "folder.badge.plus") {
                    isAddingFolder = true
                }
            } header: {
                Text("Folders")
            } footer: {
                if !canSaveHere {
                    Text("Journals go inside a folder. Open one, or add a subfolder.")
                }
            }
        }
        .navigationTitle(isRoot ? node.para.title : node.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $createdFolder) { folder in
            FolderPickerLevel(node: folder, onPick: onPick)
        }
        .alert("Add Subfolder", isPresented: $isAddingFolder) {
            TextField("Name (e.g. Travel)", text: $newFolderTitle)
            TextField("Number (optional)", text: $newFolderSeg)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) { resetFolderInput() }
            Button("Add") { addFolder() }
        } message: {
            Text("The number is appended after \(node.code). Leave it empty to use the next free number.")
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
        let seg = Int(newFolderSeg.trimmingCharacters(in: .whitespacesAndNewlines))
        resetFolderInput()
        guard !title.isEmpty else { return }
        do {
            let folder = try store.createFolder(under: node, title: title, seg: seg)
            reload()
            createdFolder = folder
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resetFolderInput() {
        newFolderTitle = ""
        newFolderSeg = ""
    }
}
