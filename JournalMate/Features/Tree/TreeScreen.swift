import SwiftUI

/// 意味軸で辿る画面。PARA → 任意の階層 → 3 種類（生データ・自分の傾向・ジャーナル） → .md。
struct TreeScreen: View {

    @Environment(Store.self) private var store

    @State private var searchText = ""
    @State private var results: [NoteWithNode] = []

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    paraSection
                } else {
                    searchSection
                }
            }
            .navigationTitle("Folders")
            .searchable(text: $searchText, prompt: "Search All Notes")
            .onChange(of: searchText) { runSearch() }
            .refreshable { try? store.reloadRoots() }
        }
    }

    private var paraSection: some View {
        Section {
            ForEach(store.roots) { root in
                NavigationLink {
                    NodeScreen(node: root)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: root.para.symbol)
                            .appFont(.title3)
                            .foregroundStyle(root.para.tint)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(root.para.displayTitle).appFont(.headline)
                            Text(root.para.subtitle)
                                .appFont(.caption1)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("PARA")
        } footer: {
            Text("Sort by how involved you are right now, not by topic or field.")
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            Section("^[\(results.count) result](inflect: true)") {
                ForEach(results) { item in
                    NavigationLink {
                        NoteDetailScreen(note: item.note, node: item.node)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.note.title).appFont(.headline)
                            HStack(spacing: 6) {
                                ParaTag(para: item.node.para)
                                Text(item.node.parentID == nil ? item.node.para.displayTitle : item.node.title)
                                    .appFont(.caption1)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func runSearch() {
        results = (try? store.search(searchText)) ?? []
    }
}
