import SwiftUI
import UniformTypeIdentifiers

/// 設定 >「外部からメモを登録」。
///
/// メモ.app には一括書き出しが無いので、前段（ショートカットで .txt に落とす）を
/// 図で示してから、後段（フォルダを選んで取り込む）を実行させる。
struct MemoImportScreen: View {

    @Environment(Store.self) private var store

    @State private var isPicking = false
    @State private var isImporting = false
    @State private var summary: ImportSummary?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Text("The Notes app has no bulk export. Use a shortcut to save your notes as .txt files, then import that folder all at once.")
                .appFont(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(ShortcutRecipe.steps.enumerated()), id: \.offset) { index, step in
                        ShortcutStepRow(number: index + 1, step: step,
                                        isLast: index == ShortcutRecipe.steps.count - 1)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("How to Build the Shortcut")
            } footer: {
                Text("In the Shortcuts app, just add the five actions above in order.")
            }

            Section {
                CalloutRow(
                    symbol: "exclamationmark.triangle.fill", tint: .orange,
                    title: "Choose \"Creation Date\", not \"Last Modified Date\"",
                    detail: "The exported .txt files are dated the day you export them. Only the file name (or frontmatter) can carry the original creation date, so if you get this wrong, everything piles up on today's date in the calendar.")
                CalloutRow(
                    symbol: "character.cursor.ibeam", tint: .blue,
                    title: "If some note names contain / or :",
                    detail: "Saving the file will fail. Add a \"Replace Text\" action before step 4 and replace the regular expression [/:] with -.")
                CalloutRow(
                    symbol: "folder.badge.gearshape", tint: .green,
                    title: "Run it once per Notes folder",
                    detail: "If you save each folder to NotesExport/<folder name>/, the same names appear under the inbox after import.")
                CalloutRow(
                    symbol: "lock", tint: .secondary,
                    title: "What doesn't come through",
                    detail: "Locked notes, and images or attachments in note bodies, are not exported.")
            } header: {
                Text("Before You Start")
            }

            Section {
                Button {
                    isPicking = true
                } label: {
                    if isImporting {
                        HStack { ProgressView(); Text("Importing…") }
                    } else {
                        Label("Choose the Exported Folder to Import", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(isImporting)
            } header: {
                Text("Import")
            } footer: {
                Text("Everything goes under \(MemoImporter.inboxPara.title) / \(MemoImporter.inboxTitle) as raw data (original, unprocessed). You can move things later in the Folders screen. The body text is never rewritten.")
            }

            if let summary {
                ImportSummarySection(summary: summary)
            }
        }
        .navigationTitle("Import Memos")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                Task { await runImport(from: url) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func runImport(from url: URL) async {
        isImporting = true
        defer { isImporting = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            // 走査とファイル読みは重いのでメインから外す。投入だけ Store（MainActor）で行う。
            let scan = try await Task.detached { try MemoImporter.scan(directory: url) }.value
            summary = try MemoImporter.importMemos(scan, into: store)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 結果

private struct ImportSummarySection: View {
    let summary: ImportSummary

    var body: some View {
        Section {
            LabeledContent("Imported") {
                Text("^[\(summary.imported) item](inflect: true)")
            }
            if summary.skipped > 0 {
                LabeledContent("Already imported") {
                    Text("^[\(summary.skipped) item](inflect: true)")
                }
            }
            if summary.unreadable > 0 {
                LabeledContent("Could not read") {
                    Text("^[\(summary.unreadable) item](inflect: true)")
                }
            }

            LabeledContent("Original creation date restored") {
                Text("^[\(summary.withOriginalDate) item](inflect: true)")
                    .foregroundStyle(summary.withSubstitutedDate == 0 ? Color.green : .primary)
            }

            if summary.withSubstitutedDate > 0 {
                LabeledContent("Export date used instead") {
                    Text("^[\(summary.withSubstitutedDate) item](inflect: true)").foregroundStyle(.orange)
                }
                Text("These memos have no date in their file names. In the shortcut's \"Format Date\" action, format the Creation Date as yyyyMMddHHmm, put it at the start of the file name, and export again. Memos already imported won't be duplicated.")
                .appFont(.caption1)
                .foregroundStyle(.secondary)
            }

            ForEach(MemoDateSource.allCases, id: \.self) { source in
                if let count = summary.dateSources[source], count > 0 {
                    LabeledContent(source.label) {
                        Text("\(count)").appFont(.caption1, monospacedDigits: true).foregroundStyle(.secondary)
                    }
                    .appFont(.caption1)
                }
            }
        } header: {
            Text("Results")
        } footer: {
            if !summary.folders.isEmpty {
                Text("Imported into:\n\(summary.folders.joined(separator: "\n"))")
                    .appFont(.caption1, monospacedDigits: true)
            }
        }
    }
}

// MARK: - ショートカットの図

/// ショートカット.app のアクション 1 個ぶん。
struct ShortcutAction {
    var name: String
    var symbol: String
    var tint: Color
    var fields: [Field] = []

    struct Field: Identifiable {
        var id: String { label }
        var label: String
        var tokens: [Token]
        /// 元のメモ作成日を運ぶ、この仕組みの要になる行。
        var isKey = false
    }

    enum Token: Hashable {
        /// そのままの文字。
        case plain(String)
        /// ショートカットの変数（青いピル）。
        case variable(String)
        /// 入力する値。
        case value(String)
    }
}

enum ShortcutRecipe {
    static let steps: [ShortcutAction] = [
        ShortcutAction(
            name: String(localized: "Find Notes"), symbol: "note.text", tint: .yellow,
            fields: [
                .init(label: String(localized: "Folder"),
                      tokens: [.value(String(localized: "(choose one Notes folder)"))]),
            ]),
        ShortcutAction(
            name: String(localized: "Repeat with Each"), symbol: "repeat", tint: .orange,
            fields: [
                .init(label: String(localized: "Input"), tokens: [.variable(String(localized: "Notes"))]),
            ]),
        ShortcutAction(
            name: String(localized: "Format Date"), symbol: "calendar", tint: .red,
            fields: [
                .init(label: String(localized: "Date"),
                      tokens: [.variable(String(localized: "Repeat Item")),
                               .plain(String(localized: "’s")),
                               .value(String(localized: "Creation Date"))],
                      isKey: true),
                .init(label: String(localized: "Date Format"), tokens: [.value(String(localized: "Custom"))]),
                .init(label: String(localized: "Custom Format"), tokens: [.value("yyyyMMddHHmm")], isKey: true),
            ]),
        ShortcutAction(
            name: String(localized: "Get Text from Input"), symbol: "text.alignleft", tint: .gray,
            fields: [
                .init(label: String(localized: "Input"), tokens: [.variable(String(localized: "Repeat Item"))]),
            ]),
        ShortcutAction(
            name: String(localized: "Save File"), symbol: "folder.fill", tint: .blue,
            fields: [
                .init(label: String(localized: "File"), tokens: [.variable(String(localized: "Text"))]),
                .init(label: String(localized: "Location"),
                      tokens: [.value(String(localized: "iCloud Drive/NotesExport/<folder name>"))]),
                .init(label: String(localized: "File Name"),
                      tokens: [.variable(String(localized: "Formatted Date")), .plain("_"),
                               .variable(String(localized: "Name")), .plain(".txt")],
                      isKey: true),
                .init(label: String(localized: "Ask Where to Save"), tokens: [.value(String(localized: "Off"))]),
            ]),
    ]
}

private struct ShortcutStepRow: View {
    let number: Int
    let step: ShortcutAction
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // 左の縦レール。アクションが上から下に流れることを示す。
            VStack(spacing: 0) {
                Text("\(number)")
                    .appFont(.caption2, weight: .bold)
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.secondary))
                Rectangle()
                    .fill(Color.secondary.opacity(isLast ? 0 : 0.3))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: step.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(step.tint))
                    Text(step.name).appFont(.subheadline, weight: .semibold)
                }

                ForEach(step.fields) { field in
                    FlowLayout(spacing: 4) {
                        Text(field.label)
                            .appFont(.caption1)
                            .foregroundStyle(.secondary)
                            .frame(width: 84, alignment: .leading)
                        ForEach(Array(field.tokens.enumerated()), id: \.offset) { _, token in
                            TokenChip(token: token, isKey: field.isKey)
                        }
                        if field.isKey {
                            Image(systemName: "arrowshape.left.fill")
                                .appFont(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.09)))
            .padding(.bottom, isLast ? 0 : 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TokenChip: View {
    let token: ShortcutAction.Token
    let isKey: Bool

    var body: some View {
        switch token {
        case .plain(let text):
            Text(text).appFont(.caption1)
        case .variable(let name):
            Text(name)
                .appFont(.caption1, weight: .medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                .foregroundStyle(Color.accentColor)
        case .value(let text):
            Text(text)
                .appFont(.caption1, monospacedDigits: true)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill((isKey ? Color.orange : Color.secondary).opacity(0.16)))
                .foregroundStyle(isKey ? Color.orange : Color.primary)
        }
    }
}

private struct CalloutRow: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .appFont(.footnote)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).appFont(.subheadline, weight: .semibold)
                Text(detail).appFont(.caption1).foregroundStyle(.secondary)
            }
        }
    }
}

/// 行に収まらなくなったら折り返す並べ方。ラベルとピルを自然に流すためだけの最小実装。
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for size in subviews.map({ $0.sizeThatFits(.unspecified) }) {
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
