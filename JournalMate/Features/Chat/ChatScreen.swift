import SwiftUI

/// メイン画面。ここでの対話がそのまま日々のジャーナルになる。
struct ChatScreen: View {

    @Environment(Store.self) private var store
    @Environment(Entitlement.self) private var entitlement
    @State private var model = ChatViewModel()
    @State private var isShowingHistory = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.messages.isEmpty {
                            EmptyChatPrompt(isPro: entitlement.isPro)
                                .padding(.top, 48)
                        }
                        ForEach(model.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        if !model.streamingText.isEmpty {
                            MessageBubble(message: Message(
                                id: "streaming", sessionID: "", role: .assistant,
                                content: model.streamingText, noteID: nil, createdAt: Date()))
                            .id("streaming")
                        }
                        if let status = model.recallStatus {
                            RecallStatusRow(text: status)
                                .id("recall")
                        }
                        if let pending = model.pendingSave {
                            SaveProposalCard(
                                draft: pending,
                                onChoose: { model.save(to: $0, store: store) },
                                onEdit: { model.editPendingSave() },
                                onCancel: { model.cancelPendingSave() })
                            .id("pendingSave")
                        }
                        if let notice = model.notice {
                            NoticeBubble(text: notice)
                                .id("notice")
                        }
                    }
                    .padding()
                }
                .onChange(of: model.messages.count) { scrollToBottom(proxy) }
                .onChange(of: model.streamingText) { scrollToBottom(proxy) }
                .onChange(of: model.recallStatus) { scrollToBottom(proxy) }
                .onChange(of: model.pendingSave?.id) { scrollToBottom(proxy) }
                .onChange(of: model.notice) { scrollToBottom(proxy) }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle(Format.dayKey(for: model.sessionDate))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Chat History", systemImage: "clock.arrow.circlepath") {
                        model.reloadSessions(store: store)
                        isShowingHistory = true
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    journalButton
                    Button("New Chat", systemImage: "square.and.pencil") {
                        model.startNewSession()
                    }
                    .disabled(model.messages.isEmpty || !model.canSwitchSession)
                }
            }
            .sheet(isPresented: $isShowingHistory) {
                ChatHistorySheet(
                    sessions: model.sessions,
                    currentID: model.sessionID,
                    canSwitch: model.canSwitchSession,
                    onOpen: { model.open($0, store: store) },
                    onDelete: { model.delete($0, store: store) })
            }
            .sheet(item: $model.paywall) { feature in
                PaywallSheet(feature: feature)
            }
            .sheet(item: $model.draft) { draft in
                JournalDraftSheet(draft: draft) { model.commit($0, store: store) }
            }
            .alert("Error", isPresented: .constant(model.errorMessage != nil)) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .task { model.load(store: store) }
        }
    }

    // MARK: - 部品

    @ViewBuilder
    private var journalButton: some View {
        if model.isExtracting {
            ProgressView()
        } else {
            Button("Save to Journal", systemImage: "square.and.arrow.down") {
                // 無料プランでは押した瞬間に Paywall。
                guard entitlement.isPro else {
                    model.paywall = .journalExtract
                    return
                }
                Task { await model.extractJournal(store: store, entitlement: entitlement) }
            }
            .disabled(entitlement.isPro
                      && (!model.unsavedMessages.contains { $0.role == .user } || model.pendingSave != nil))
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            MultilineTextInput(
                placeholder: model.pendingSave != nil ? String(localized: "Reply with a folder name")
                    : entitlement.isPro ? String(localized: "Talk about what's on your mind")
                                        : String(localized: "Write what's on your mind"),
                text: $model.input,
                minHeight: 42,
                maxHeight: 142)
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: .rect(cornerRadius: 20))

            Button {
                Task { await model.send(store: store, entitlement: entitlement) }
            } label: {
                Image(systemName: model.isResponding ? "ellipsis" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty || model.isResponding)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .keepsKeyboardOnTap()
        // 無料プランでは入力欄に触れた瞬間に Paywall。
        .proGate(.aiChat)
        .background(.bar)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if model.notice != nil {
                proxy.scrollTo("notice", anchor: .bottom)
            } else if model.pendingSave != nil {
                proxy.scrollTo("pendingSave", anchor: .bottom)
            } else if model.recallStatus != nil {
                proxy.scrollTo("recall", anchor: .bottom)
            } else if !model.streamingText.isEmpty {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let last = model.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private struct EmptyChatPrompt: View {
    let isPro: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(isPro ? "What were you thinking about today?" : "Keep journaling with Pro")
                .appFont(.headline)
            Text(isPro
                 ? "Tap \"Save to Journal\" to turn what you said into a journal entry, sorted into PARA automatically."
                 : "Talking with AI and writing journals need a plan. Your past journals are still in Calendar and Folders, and you can export them anytime.")
                .appFont(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // 記録するだけの場所だと思われやすいので、過去を探せることも最初に見せておく。
            if isPro {
                Label {
                    Text("You can also search past journals. Ask something like \"What was I journaling about on this day last month?\"")
                } icon: {
                    Image(systemName: "magnifyingglass")
                }
                .appFont(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .padding(12)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }
}
