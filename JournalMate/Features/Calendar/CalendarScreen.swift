import SwiftUI

/// 時間軸で振り返る画面。日付を選ぶとその日のジャーナルが出る。
/// 上部の絞り込み（PARA のタブ＋フォルダのチェック）で、カレンダーに映す範囲を切り替える。
struct CalendarScreen: View {

    @Environment(Store.self) private var store

    @State private var selectedDate = Date()
    @State private var markers: [String: (count: Int, para: Para)] = [:]
    @State private var notes: [NoteWithNode] = []
    @State private var errorMessage: String?

    /// nil は「すべての PARA」。タブの左端。
    @State private var para: Para?
    /// PARA ごとに覚えておく。タブを行き来してもチェックが消えないように。
    @State private var checkedFolderIDs: [Para: Set<String>] = [:]
    /// 選択中 PARA の直下フォルダ。チェックボックスの元。
    @State private var folders: [Node] = []
    /// いま表示している月。絞り込みが変わったとき、同じ月の装飾を取り直すために覚える。
    @State private var visibleMonth = Calendar(identifier: .gregorian)
        .dateComponents([.year, .month], from: Date())

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CalendarFilterBar(folders: folders,
                                  para: $para,
                                  checkedFolderIDs: checkedBinding)

                // カレンダーは枠に固定せず、ジャーナル一覧と一緒にスクロールさせる。
                // その日の件数が多くても、下まで読み進められるように。
                ScrollView {
                    VStack(spacing: 0) {
                        CalendarViewRepresentable(
                            markers: markers,
                            selectedDate: $selectedDate,
                            onVisibleMonthChange: { month in
                                visibleMonth = month
                                loadMarkers(around: month)
                            })
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        if notes.isEmpty {
                            ContentUnavailableView(
                                "No Notes on This Day",
                                systemImage: "calendar.badge.exclamationmark",
                                description: Text(emptyDescription))
                            .padding(.vertical, 32)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(notes) { item in
                                    NavigationLink {
                                        NoteDetailScreen(note: item.note, node: item.node)
                                    } label: {
                                        HStack {
                                            DayNoteRow(item: item)
                                            Image(systemName: "chevron.right")
                                                .appFont(.footnote, weight: .semibold)
                                                .foregroundStyle(.tertiary)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .contentShape(.rect)
                                    }
                                    .buttonStyle(.plain)

                                    Divider()
                                        .padding(.leading, 16)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: selectedDate) { loadNotes() }
            .onChange(of: para) {
                loadFolders()
                reload()
            }
            .onChange(of: checkedFolderIDs) { reload() }
            // 他のタブでフォルダを作って戻ってきたときに、チェックボックスを追い付かせる。
            .onAppear { loadFolders() }
            .task { reload() }
        }
    }

    // MARK: - 絞り込み

    /// 選択中 PARA のチェック集合。PARA 未選択のときは書き込み先が無いので読み捨てる。
    private var checkedBinding: Binding<Set<String>> {
        Binding(
            get: { para.flatMap { checkedFolderIDs[$0] } ?? [] },
            set: { newValue in
                guard let para else { return }
                checkedFolderIDs[para] = newValue
            })
    }

    /// 問い合わせに渡す code の前方一致。
    /// PARA 未選択なら空＝全件、チェックが無ければ PARA 全体、あればそのフォルダの部分木だけ。
    private var codePrefixes: [String] {
        guard let para, let root = store.root(for: para) else { return [] }
        let checked = checkedFolderIDs[para] ?? []
        let chosen = folders.filter { checked.contains($0.id) }
        return chosen.isEmpty ? [root.code] : chosen.map(\.code)
    }

    private var emptyDescription: String {
        guard let para else {
            return String(localized: "What you talk about in Chat appears here by date.")
        }
        let checked = folders.filter { (checkedFolderIDs[para] ?? []).contains($0.id) }
        if checked.isEmpty {
            return String(localized: "No notes on this day in \(para.displayTitle). Use the tabs above to widen the range.")
        }
        let names = checked.map(\.title).formatted(.list(type: .and))
        return String(localized: "No notes on this day in \(names).")
    }

    // MARK: - 読み込み

    private func loadFolders() {
        guard let para, let root = store.root(for: para) else {
            folders = []
            return
        }
        do {
            folders = try store.children(of: root)
            // 消えたフォルダのチェックは落とす。残すと「何も出ない」絞り込みになる。
            let alive = Set(folders.map(\.id))
            if let current = checkedFolderIDs[para] {
                let pruned = current.intersection(alive)
                if pruned != current { checkedFolderIDs[para] = pruned }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload() {
        loadMarkers(around: visibleMonth)
        loadNotes()
    }

    /// 表示月とその前後 1 か月ぶんの装飾をまとめて取る。
    private func loadMarkers(around components: DateComponents) {
        let calendar = Calendar(identifier: .gregorian)
        guard let month = calendar.date(from: DateComponents(
            year: components.year, month: components.month, day: 1)),
              let start = calendar.date(byAdding: .month, value: -1, to: month),
              let end = calendar.date(byAdding: .month, value: 2, to: month) else { return }
        do {
            markers = try store.dayMarkers(from: start, to: end, codePrefixes: codePrefixes)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadNotes() {
        do {
            notes = try store.notes(on: selectedDate, codePrefixes: codePrefixes)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 日付一覧の 1 行。PARA タグとフォルダ名と時刻を出す（番号は索引用なので出さない）。
private struct DayNoteRow: View {
    let item: NoteWithNode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ParaTag(para: item.node.para)
                Text(item.node.title)
                    .appFont(.caption1)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(item.note.occurredAt, format: .dateTime.hour().minute())
                    .appFont(.caption1)
                    .foregroundStyle(.tertiary)
            }
            Text(item.note.title)
                .appFont(.headline)
            if !item.note.preview.isEmpty {
                Text(item.note.preview)
                    .appFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ParaTag: View {
    let para: Para

    var body: some View {
        Text(para.displayTitle)
            .appFont(.caption2, weight: .semibold)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(para.tint.opacity(0.18), in: .capsule)
            .foregroundStyle(para.tint)
    }
}
