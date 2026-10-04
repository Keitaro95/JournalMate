import SwiftUI

/// 1 つのディレクトリ。サブディレクトリと、その下の 3 層を出す。
struct NodeScreen: View {

    @Environment(Store.self) private var store

    let node: Node

    @State private var children: [Node] = []
    @State private var counts: [Layer: Int] = [:]
    @State private var isAddingFolder = false
    @State private var newFolderTitle = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(children) { child in
                    NavigationLink {
                        NodeScreen(node: child)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .foregroundStyle(child.para.tint)
                            Text(child.title)
                        }
                    }
                }
                .onDelete(perform: deleteChildren)

                Button("Add Subfolder", systemImage: "folder.badge.plus") {
                    isAddingFolder = true
                }
            } header: {
                Text("Subfolders")
            } footer: {
                if children.isEmpty {
                    Text("Divide by topics you care about, like life, travel, or relationships. Optional.")
                }
            }

            Section {
                ForEach(Layer.allCases) { layer in
                    NavigationLink {
                        LayerScreen(node: node, layer: layer)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: layer.symbol)
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(layer.title).appFont(.body, monospacedDigits: true)
                                Text(layer.summary)
                                    .appFont(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("\(counts[layer] ?? 0)")
                                .appFont(.caption1, monospacedDigits: true)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("Inside This Folder")
            } footer: {
                Text("Raw data and journals are the ingredients; your patterns are blended from them. Originals are never rewritten, so nothing is lost even if you change the PARA category later.")
            }

            // 番号（node.code）はファイル名と AI の検索の索引に使うだけなので、画面には出さない。
            Section("Path") {
                LabeledContent("Path", value: node.path)
                    .appFont(.caption1, monospacedDigits: true)
            }
        }
        .navigationTitle(node.parentID == nil ? node.para.displayTitle : node.title)
        .navigationBarTitleDisplayMode(.inline)
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
        .onAppear { reload() }
    }

    private func reload() {
        do {
            children = try store.children(of: node)
            for layer in Layer.allCases {
                counts[layer] = try store.notes(in: node, layer: layer).count
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addFolder() {
        let title = newFolderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderTitle = ""
        guard !title.isEmpty else { return }
        do {
            // 番号は画面に出さないので、いつも空き番号を自動で振る。
            try store.createFolder(under: node, title: title)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteChildren(at offsets: IndexSet) {
        do {
            for index in offsets {
                try store.delete(children[index])
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
