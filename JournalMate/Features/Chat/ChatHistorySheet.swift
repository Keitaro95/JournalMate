import SwiftUI

/// 左上から開く過去の対話の一覧。履歴はこの端末の DB にだけあり、バックアップには入らない。
struct ChatHistorySheet: View {

    let sessions: [ChatSession]
    let currentID: String
    /// 返答やジャーナル化の途中は、別の対話に切り替えられない。
    let canSwitch: Bool
    let onOpen: (ChatSession) -> Void
    let onDelete: (ChatSession) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No chats yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Past conversations will appear here."))
                } else {
                    List {
                        ForEach(sessions) { session in
                            Button {
                                onOpen(session)
                                dismiss()
                            } label: {
                                row(session)
                            }
                            .foregroundStyle(.primary)
                            .disabled(!canSwitch && session.id != currentID)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    onDelete(session)
                                }
                            }
                        }
                        Section {
                        } footer: {
                            Text("Chat history stays on this device and isn't included in backups. To keep a conversation, save it to your journal.")
                        }
                    }
                }
            }
            .navigationTitle("Chat History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ session: ChatSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title.isEmpty ? String(localized: "Untitled chat") : session.title)
                    .appFont(.body)
                    .lineLimit(2)
                Text(session.updatedAt, format: .dateTime.year().month().day().hour().minute())
                    .appFont(.caption1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if session.id == currentID {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(.rect)
    }
}
