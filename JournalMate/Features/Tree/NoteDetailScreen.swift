import SwiftUI

/// 最下層の .md。表示と編集。
struct NoteDetailScreen: View {

    @Environment(Store.self) private var store
    @Environment(Entitlement.self) private var entitlement

    let note: Note
    let node: Node
    var startsEditing = false

    @State private var title = ""
    @State private var body_ = ""
    @State private var isEditing = false
    @State private var errorMessage: String?
    @State private var paywall: ProFeature?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if isEditing {
                    TextField("Title", text: $title)
                        .appFont(.title2, weight: .semibold)
                        .textFieldStyle(.plain)
                    Divider()
                    MultilineTextInput(
                        placeholder: "",
                        text: $body_,
                        minHeight: 320)
                } else {
                    Text(title)
                        .appFont(.title2, weight: .semibold)
                    MarkdownText(markdown: body_)
                }
            }
            .padding()
        }
        .navigationTitle(note.filename)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "Done" : "Edit") {
                    // 書き直すのも有料。編集中に切れた場合は、書いた分を失わないよう保存は通す。
                    guard isEditing || entitlement.isPro else {
                        paywall = .journalWrite
                        return
                    }
                    if isEditing { save() }
                    isEditing.toggle()
                }
            }
        }
        .sheet(item: $paywall) { feature in
            PaywallSheet(feature: feature)
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            title = note.title
            body_ = note.body
            isEditing = startsEditing && entitlement.isPro
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ParaTag(para: node.para)
                Text(note.layer.title)
                    .appFont(.caption2, weight: .semibold)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
                Spacer()
                Text(note.occurredAt, format: .dateTime.year().month().day().hour().minute())
                    .appFont(.caption1)
                    .foregroundStyle(.secondary)
            }
            Text("\(node.path)/\(note.layer.directoryName)/")
                .appFont(.caption2, monospacedDigits: true)
                .foregroundStyle(.tertiary)
        }
    }

    private func save() {
        do {
            try store.updateNote(note, title: title, body: body_)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 最低限の Markdown 表示。見出し・箇条書き・引用・区切り線を行単位で描く。
/// 行内の強調やリンクは `AttributedString` に任せる。
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                row(for: line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func row(for line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Color.clear.frame(height: 2)
        } else if trimmed == "---" || trimmed == "***" {
            Divider()
        } else if trimmed.hasPrefix("### ") {
            inline(String(trimmed.dropFirst(4))).appFont(.headline)
        } else if trimmed.hasPrefix("## ") {
            inline(String(trimmed.dropFirst(3))).appFont(.title3, weight: .semibold)
        } else if trimmed.hasPrefix("# ") {
            inline(String(trimmed.dropFirst(2))).appFont(.title2, weight: .bold)
        } else if trimmed.hasPrefix("> ") {
            inline(String(trimmed.dropFirst(2)))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().frame(width: 2).foregroundStyle(.tertiary)
                }
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                inline(String(trimmed.dropFirst(2)))
            }
        } else {
            inline(line)
        }
    }

    private func inline(_ text: String) -> Text {
        // インライン記法だけを解釈する。失敗したら素のテキストにする。
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
