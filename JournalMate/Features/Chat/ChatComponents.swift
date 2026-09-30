import SwiftUI

// チャットの吹き出し。Chat 画面とオンボーディング（体験・説明のモック）で使い回す。

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            Text(message.content)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    message.role == .user ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                                          : AnyShapeStyle(.quaternary),
                    in: .rect(cornerRadius: 18))
            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }
}

/// チャットの中で保存先を尋ねる吹き出し。AI の側に出す。
/// 候補を押せばそのまま保存、文字で答えても良い（`ChatViewModel.answerSaveQuestion`）。
struct SaveProposalCard: View {
    let draft: JournalDraft
    let onChoose: (SaveDestination) -> Void
    let onEdit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 12) {
                if !draft.summary.isEmpty {
                    Text(draft.summary)
                }
                Text("Where should I save this?")

                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.title).appFont(.subheadline, weight: .bold)
                    Text(draft.body)
                        .appFont(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.opacity(0.6), in: .rect(cornerRadius: 10))

                ForEach(Array(draft.destinations.enumerated()), id: \.element.id) { index, destination in
                    Button { onChoose(destination) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: destination.para.symbol)
                                Text(destination.displayPath).bold()
                                if destination.isNew {
                                    Text("New").appFont(.caption2, weight: .bold)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.tint.opacity(0.15), in: .capsule)
                                }
                            }
                            if !destination.reason.isEmpty {
                                Text(destination.reason)
                                    .appFont(.caption1)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .tint(index == 0 ? .accentColor : .secondary)
                }

                HStack {
                    Button("Choose another place or edit…", action: onEdit)
                    Spacer()
                    Button("Don't save", role: .cancel, action: onCancel)
                        .foregroundStyle(.secondary)
                }
                .appFont(.footnote)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.quaternary, in: .rect(cornerRadius: 18))
            Spacer(minLength: 24)
        }
    }
}

/// アプリからの一言。会話ログには残らない。
/// AI が過去のジャーナルを探しているあいだの一行。返答が止まって見えないように出す。
struct RecallStatusRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Label(text, systemImage: "clock.arrow.circlepath")
                .appFont(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NoticeBubble: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .appFont(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
    }
}
