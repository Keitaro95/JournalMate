import SwiftUI

/// カレンダーの上に置く絞り込み。上段が PARA のタブ、下段がその直下フォルダのチェックボックス。
///
/// 「いまカレンダーが何を映しているか」を常に 2 行で見せるのが狙いなので、
/// 折りたたまずに出しっぱなしにする。
struct CalendarFilterBar: View {

    /// 選択中 PARA の直下フォルダ。`para` が nil のときは空。
    let folders: [Node]
    /// nil は「すべての PARA」。タブの左端。
    @Binding var para: Para?
    /// チェックの入ったフォルダの id。空なら PARA 全体を出す。
    @Binding var checkedFolderIDs: Set<String>

    var body: some View {
        VStack(spacing: 0) {
            ParaTabBar(selection: $para)
            if let para {
                folderRow(tint: para.tint)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.bar)
        .animation(.snappy(duration: 0.22), value: para)
    }

    @ViewBuilder
    private func folderRow(tint: Color) -> some View {
        if folders.isEmpty {
            Text("No folders here yet. Folders you create in the Folders screen appear here.")
                .appFont(.caption1)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    FilterChip(title: String(localized: "All"),
                               isOn: checkedFolderIDs.isEmpty, tint: tint) {
                        checkedFolderIDs.removeAll()
                    }
                    ForEach(folders) { folder in
                        FilterChip(title: folder.title,
                                   isOn: checkedFolderIDs.contains(folder.id), tint: tint) {
                            toggle(folder)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    private func toggle(_ folder: Node) {
        withAnimation(.snappy(duration: 0.18)) {
            if checkedFolderIDs.contains(folder.id) {
                checkedFolderIDs.remove(folder.id)
            } else {
                checkedFolderIDs.insert(folder.id)
            }
        }
    }
}

// MARK: - PARA のタブ

/// PARA を切り替える横並びのタブ。下線が現在のタブを指す。
/// `Picker(.segmented)` では PARA ごとの色とアイコンを出せないので手で組む。
struct ParaTabBar: View {

    @Binding var selection: Para?

    @Namespace private var underline

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                tab(nil, title: String(localized: "All"), symbol: "square.grid.2x2", tint: .accentColor)
                ForEach(Para.allCases) { para in
                    tab(para, title: para.displayTitle, symbol: para.symbol, tint: para.tint)
                }
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // 下線はタブ側に描くので、区切り線は内容の後ろに敷く。
        .background(alignment: .bottom) {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private func tab(_ para: Para?, title: String, symbol: String, tint: Color) -> some View {
        let isSelected = selection == para
        return Button {
            withAnimation(.snappy(duration: 0.22)) { selection = para }
        } label: {
            VStack(spacing: 8) {
                Label(title, systemImage: symbol)
                    .appFont(.subheadline, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? tint : Color.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .fixedSize()

                Capsule()
                    .fill(isSelected ? tint : .clear)
                    .frame(height: 2)
                    .modifier(UnderlineMatch(isSelected: isSelected, namespace: underline))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 選択中のタブだけを `matchedGeometryEffect` の当事者にして、下線をタブ間で滑らせる。
private struct UnderlineMatch: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if isSelected {
            content.matchedGeometryEffect(id: "paraTabUnderline", in: namespace)
        } else {
            content
        }
    }
}

// MARK: - チェックボックスのチップ

private struct FilterChip: View {
    let title: String
    /// フォルダの番号。ファイル名の接頭辞と同じものを見せて、ツリーと結び付ける。
    let isOn: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? tint : Color.secondary)
                Text(title)
                    .lineLimit(1)
            }
            .appFont(.subheadline)
            .foregroundStyle(isOn ? Color.primary : .secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(isOn ? tint.opacity(0.14) : Color(uiColor: .secondarySystemFill),
                        in: .capsule)
            .overlay {
                Capsule().stroke(isOn ? tint.opacity(0.45) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    @Previewable @State var para: Para? = .projects
    @Previewable @State var checked: Set<String> = []

    CalendarFilterBar(
        folders: [
            Node(id: "a", parentID: nil, para: .projects, seg: 1, code: "01", path: "/Projects/引っ越し",
                 title: "引っ越し", depth: 1, sortOrder: 0, createdAt: .now, updatedAt: .now),
            Node(id: "b", parentID: nil, para: .projects, seg: 2, code: "02", path: "/Projects/資格",
                 title: "資格の勉強", depth: 1, sortOrder: 1, createdAt: .now, updatedAt: .now),
        ],
        para: $para,
        checkedFolderIDs: $checked)
}
