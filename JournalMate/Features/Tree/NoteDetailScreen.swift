import SwiftUI

/// 最下層の .md。表示と編集。
struct NoteDetailScreen: View {

    @Environment(Store.self) private var store

    var startsEditing = false

    /// 表示中のノートと置き場所。保存先を変えると両方とも新しいものに差し替わる。
    @State private var note: Note
    @State private var node: Node
    @State private var title = ""
    @State private var body_ = ""
    @State private var isEditing = false
    @State private var isPickingFolder = false
    /// 移した先のフォルダの名前。「{フォルダ名}に移しました」に使う。
    @State private var movedFolder: String?
    @State private var errorMessage: String?

    init(note: Note, node: Node, startsEditing: Bool = false) {
        _note = State(initialValue: note)
        _node = State(initialValue: node)
        self.startsEditing = startsEditing
    }

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
        .navigationTitle(node.parentID == nil ? node.para.displayTitle : node.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "Done" : "Edit") {
                    if isEditing { save() }
                    isEditing.toggle()
                }
            }
        }
        .sheet(isPresented: $isPickingFolder) {
            FolderPickerSheet(layer: note.layer, isMoving: true) { move(to: $0) }
        }
        .alert(movedFolder.map { String(localized: "Moved to \($0)") } ?? "",
               isPresented: .constant(movedFolder != nil)) {
            Button("OK") { movedFolder = nil }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            title = note.title
            body_ = note.body
            isEditing = startsEditing
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
            locationButton
        }
    }

    /// 置き場所のパス。押すと Journal タブで書くときと同じフォルダ選択が開き、選んだ先へ移す。
    private var locationButton: some View {
        Button {
            isPickingFolder = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(node.para.tint)
                Text(verbatim: "\(node.path)/\(note.layer.directoryName)/")
                    .appFont(.caption2, monospacedDigits: true)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Image(systemName: "chevron.right")
                    .appFont(.caption2, weight: .semibold)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Change Folder"))
        .accessibilityValue(Text(verbatim: "\(node.path)/\(note.layer.directoryName)/"))
    }

    private func save() {
        do {
            try store.updateNote(note, title: title, body: body_)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 本文と日付はそのまま、置き場所だけを変える。
    private func move(to destination: Node) {
        guard destination.id != node.id else { return }
        do {
            // ファイル名は題名から作るので、書きかけの題名を保存して読み直してから移す。
            if isEditing {
                try store.updateNote(note, title: title, body: body_)
                if let saved = try store.note(id: note.id) { note = saved }
            }
            try store.move(note, to: destination)
            if let moved = try store.note(id: note.id) { note = moved }
            node = destination
            movedFolder = destination.parentID == nil ? destination.para.displayTitle : destination.title
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
