import SwiftUI

/// 「試しにジャーナリングしてみましょう」。本物の AI と話して、その日のジャーナルを 1 本保存する。
///
/// 対話はオンボーディング専用の小さな無料枠（`ProFeature.onboardingChat`）で呼ぶ。
/// ここでは Paywall を出さない。AI が使えなくても、書いたものはそのまま保存できる。
/// 会話は今日のセッションに入るので、終わった後の Chat 画面にも続きが残る。
struct OnboardingJournalStep: View {

    @Environment(Store.self) private var store
    @Environment(Entitlement.self) private var entitlement

    let onFinish: () -> Void

    @State private var model = ChatViewModel()
    @State private var isAskingConsent = false
    /// 同意の画面は 1 度だけ出す。断られたら、AI なしで書いて保存する流れに進む。
    @State private var hasAskedConsent = false

    private var hasSaved: Bool { model.lastSavedPath != nil }

    private var canExtract: Bool {
        model.unsavedMessages.contains { $0.role == .user }
            && model.pendingSave == nil && !model.isResponding && !hasSaved
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        header
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
                        if let pending = model.pendingSave {
                            SaveProposalCard(
                                draft: pending,
                                onChoose: { model.save(to: $0, store: store) },
                                onEdit: { model.editPendingSave() },
                                onCancel: { model.cancelPendingSave() })
                            .id("pendingSave")
                        }
                        if let path = model.lastSavedPath {
                            SavedCard(path: path)
                                .id("saved")
                        } else if let notice = model.notice {
                            NoticeBubble(text: notice)
                                .id("notice")
                        }
                    }
                    .padding()
                }
                .onChange(of: model.messages.count) { scrollToBottom(proxy) }
                .onChange(of: model.streamingText) { scrollToBottom(proxy) }
                .onChange(of: model.pendingSave?.id) { scrollToBottom(proxy) }
                .onChange(of: model.lastSavedPath) { scrollToBottom(proxy) }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .navigationTitle("Try Journaling")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !hasSaved {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Skip", action: onFinish)
                    }
                }
            }
            .sheet(item: $model.draft) { draft in
                JournalDraftSheet(draft: draft) { model.commit($0, store: store) }
            }
            .sheet(isPresented: $isAskingConsent, onDismiss: {
                Task { await model.send(store: store, entitlement: entitlement) }
            }) {
                ConsentSheet()
            }
            .alert("Error", isPresented: .constant(model.errorMessage != nil)) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .task { prepare() }
        }
    }

    // MARK: - 部品

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Let's try journaling")
                    .appFont(.title3, weight: .bold)
                Text("Talk with AI for a bit, then tap \"Turn into Journal\". Your first entry will be saved to today.")
                    .appFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            MessageBubble(message: Message(
                id: "prompt", sessionID: "", role: .assistant,
                content: String(localized: "Tell me one thing that happened today. Anything is fine."),
                noteID: nil, createdAt: Date()))
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if hasSaved {
            Button {
                onFinish()
            } label: {
                Text("Next").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .background(.bar)
        } else {
            VStack(spacing: 8) {
                if canExtract || model.isExtracting {
                    Button {
                        Task { await model.extractJournal(store: store, entitlement: entitlement) }
                    } label: {
                        HStack {
                            if model.isExtracting { ProgressView() }
                            Label("Turn into Journal", systemImage: "square.and.arrow.down")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isExtracting)
                }
                composer
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            MultilineTextInput(
                placeholder: model.pendingSave != nil ? String(localized: "Reply with a folder name")
                                                      : String(localized: "Talk about what's on your mind"),
                text: $model.input,
                minHeight: 42,
                maxHeight: 142)
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: .rect(cornerRadius: 20))

            Button {
                send()
            } label: {
                Image(systemName: model.isResponding ? "ellipsis" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty || model.isResponding)
        }
    }

    // MARK: - 動作

    /// 保存先の候補になる最初のフォルダを作り、対話をオンボーディング用の枠に切り替える。
    /// `ensureFolder` は既にあれば何もしないので、入り直しても増えない。
    private func prepare() {
        model.chatFeature = .onboardingChat
        model.extractFeature = .onboardingExtract
        model.offersPaywall = false
        do {
            try store.ensureFolder(para: .areas, components: [String(localized: "Work")])
            try store.ensureFolder(para: .areas, components: [String(localized: "Life")])
            try store.ensureFolder(para: .resources, components: [String(localized: "About Me")])
            try store.reloadRoots()
        } catch {
            model.errorMessage = error.localizedDescription
        }
        model.load(store: store)
    }

    /// 最初の送信の前に、AI へ送ることの同意を 1 度だけ尋ねる。送るのはシートを閉じた後。
    private func send() {
        if !entitlement.hasAIConsent, !hasAskedConsent, model.pendingSave == nil {
            hasAskedConsent = true
            isAskingConsent = true
            return
        }
        Task { await model.send(store: store, entitlement: entitlement) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if hasSaved {
                proxy.scrollTo("saved", anchor: .bottom)
            } else if model.pendingSave != nil {
                proxy.scrollTo("pendingSave", anchor: .bottom)
            } else if !model.streamingText.isEmpty {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let last = model.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

/// 保存できたことと、それがどこで見られるかを伝える。
private struct SavedCard: View {

    let path: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text("Your first journal is ready")
                .appFont(.headline)
            Text("You can look back on it anytime in Calendar.")
                .appFont(.footnote)
                .foregroundStyle(.secondary)
            Text(path)
                .appFont(.caption1, monospacedDigits: true)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 18))
    }
}

/// AI に送ることへの同意。設定と同じ `AIConsentSection` を出す。
private struct ConsentSheet: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("To get replies from AI, allow what you write to be sent to AI. You can also continue without it and just write.")
                        .appFont(.subheadline)
                }
                AIConsentSection()
            }
            .navigationTitle("Sending Data to AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
