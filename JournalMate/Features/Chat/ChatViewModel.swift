import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {

    var messages: [Message] = []
    var input = ""
    /// 生成中のテキスト。確定したら `messages` に移す。
    var streamingText = ""
    var isResponding = false
    /// AI が過去のジャーナルを探しているあいだの一言（「"引っ越し" を探しています」）。
    var recallStatus: String?
    /// 確認シートで開くジャーナル案。「別の場所を選ぶ・内容を直す」とき、
    /// または AI が保存先の候補を出せなかったときに使う。
    var draft: JournalDraft?
    /// チャットの中で保存先を尋ねている案。返事（ボタンか文字）で保存先が決まるまで DB には入れない。
    var pendingSave: JournalDraft?
    /// 保存先を尋ねているあいだの、アプリからの一言（「保存しました」「どのフォルダか分かりませんでした」）。
    /// 会話ログには入れない（次の返答やジャーナル化の材料にしないため）。
    var notice: String?
    var isExtracting = false
    /// 最後に保存したジャーナルのフォルダ（"/Areas/Work"）。オンボーディングの完了表示に使う。
    private(set) var lastSavedPath: String?
    var errorMessage: String?
    /// Paywall を出す引き金になった機能。画面がシートを開く。
    var paywall: ProFeature?
    /// 対話をどの機能として呼ぶか。オンボーディングの体験だけ `.onboardingChat`（小さな無料枠）にする。
    var chatFeature: ProFeature = .aiChat
    /// ジャーナル化をどの機能として呼ぶか。オンボーディングの体験だけ `.onboardingExtract`（1 回の無料枠）にする。
    var extractFeature: ProFeature = .journalExtract
    /// false なら Paywall を出さない。オンボーディングの途中で課金の壁を見せないため。
    /// そのときも書いたものは残り、自分の言葉のままジャーナルにできる。
    var offersPaywall = true
    /// 対話の Paywall は 1 セッションに 1 度だけ。毎回出すと書くこと自体が億劫になる。
    private var hasOfferedChatPro = false
    /// 1 日の上限の知らせも 1 セッションに 1 度だけ。
    private var hasWarnedBudget = false

    /// いま開いている対話。右上の「新しいチャット」で切り替わる。
    /// 以前の版は日付（"2026-09-28"）を ID にしていたので、古い履歴はその形のまま残っている。
    private(set) var sessionID = UUID().uuidString
    /// 左上の履歴一覧に出す過去の対話。
    private(set) var sessions: [ChatSession] = []
    /// いま開いている対話を始めた日。空の新しい対話なら今日。
    var sessionDate: Date { messages.first?.createdAt ?? Date() }

    /// 本人が作ったフォルダを読んだうえで相手をする。
    /// 後で「どのフォルダの話か」を決めるので、会話の中でそれが分かるようにしておく。
    static func system(folders: [Node]) -> String {
        """
        あなたはユーザーの思考の相手役です。ユーザーが今日考えていること、感じたこと、
        引っかかっていることを引き出してください。

        - 答えを急がず、まず相手の言葉を正確に受け取る
        - 一度にひとつだけ質問する
        - 一般論の説教をしない。相手の具体に寄る
        - 返答は 3〜5 文程度に収める

        # この人が話題にしたい領域（本人が最初の設定で作ったフォルダ）
        \(JournalExtractor.folderList(folders))

        この会話は後でジャーナルとして、上のどれかのフォルダに保存されます。
        - 話がどの領域のことか分かれば、それを踏まえて聞く。フォルダ名を口に出す必要はない
        - どの領域か曖昧なら、話の流れの中で自然に確かめる（締め切りのある取り組みか、
          ずっと続く責任か、興味で調べていることか）
        - 分類のために話を誘導しない。本人が話したいことが先
        """
    }

    /// 最後にジャーナル化した後の会話。同じ日に 2 回目を保存しても、前の分を二重に書かない。
    var unsavedMessages: [Message] {
        guard let last = messages.lastIndex(where: { $0.noteID != nil }) else { return messages }
        return Array(messages[(last + 1)...])
    }

    // MARK: - 読み込み

    /// 今日話した対話があれば続きから、無ければ新しい対話で始める。
    func load(store: Store) {
        do {
            sessions = try store.chatSessions()
            if let latest = sessions.first, Calendar.current.isDateInToday(latest.updatedAt) {
                sessionID = latest.id
            }
            messages = try store.messages(sessionID: sessionID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadSessions(store: Store) {
        do {
            sessions = try store.chatSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 返答やジャーナル化の途中で切り替えると、結果が別の対話に書き込まれてしまう。
    var canSwitchSession: Bool { !isResponding && !isExtracting }

    /// 右上の「新しいチャット」。前の対話はそのまま履歴に残る。
    func startNewSession() {
        guard canSwitchSession else { return }
        switchTo(UUID().uuidString, messages: [])
    }

    /// 履歴から過去の対話を開く。
    func open(_ session: ChatSession, store: Store) {
        guard canSwitchSession, session.id != sessionID else { return }
        do {
            switchTo(session.id, messages: try store.messages(sessionID: session.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 履歴から消す。開いている対話を消したら、新しい対話にする。
    func delete(_ session: ChatSession, store: Store) {
        guard session.id != sessionID || canSwitchSession else { return }
        do {
            try store.deleteChatSession(id: session.id)
            sessions.removeAll { $0.id == session.id }
            if session.id == sessionID {
                switchTo(UUID().uuidString, messages: [])
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func switchTo(_ id: String, messages: [Message]) {
        sessionID = id
        self.messages = messages
        input = ""
        streamingText = ""
        recallStatus = nil
        draft = nil
        pendingSave = nil
        notice = nil
    }

    // MARK: - 送信

    func send(store: Store, entitlement: Entitlement) async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        input = ""

        // 保存先を尋ねているあいだの返事は会話ではない。ログにも AI にも渡さない。
        if pendingSave != nil {
            answerSaveQuestion(text, store: store)
            return
        }
        notice = nil

        do {
            let message = try store.appendMessage(sessionID: sessionID, role: .user, content: text)
            messages.append(message)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // 1 日の上限。走り出したストリームは止められないので、始める手前で見る。
        if let budget = entitlement.exhaustedBudget(in: store) {
            if !hasWarnedBudget {
                hasWarnedBudget = true
                errorMessage = budget.exhaustedMessage
            }
            return
        }

        // 無料ユーザーは AI なし。書いた内容はそのまま残るので記録には使える。
        // 返答だけが Pro であることを、書き終わったこの瞬間に 1 度だけ伝える。
        guard entitlement.access(to: chatFeature, in: store).isAllowed,
              let client = entitlement.client(meter: store, for: chatFeature) else {
            if !hasOfferedChatPro || !offersPaywall {
                hasOfferedChatPro = true
                showPaywall(.aiChat)
            }
            return
        }

        isResponding = true
        streamingText = ""
        defer { isResponding = false }

        let turns = messages.map {
            ClaudeClient.Turn(role: $0.role == .user ? "user" : "assistant", text: $0.content)
        }
        let folders = JournalExtractor.candidateNodes(from: (try? store.allNodes()) ?? [])
        defer { recallStatus = nil }

        do {
            // 過去のジャーナルから引き出す（Pro）。まず検索意図を読み取り、要るときだけ探させる。
            // オンボーディングの体験（`.onboardingChat`）はまだ記録が無いので読み取らない。
            let intent = chatFeature == .aiChat
                ? try await readRecallIntent(text, client: client, folders: folders)
                : nil

            if chatFeature == .aiChat, intent?.needsRecall != false {
                if let intent, !intent.intent.isEmpty {
                    recallStatus = String(localized: "Looking back: \(intent.intent)")
                }
                let events = client.streamReply(
                    system: Self.system(folders: folders) + JournalRecall.systemAddendum(),
                    turns: turns, tools: JournalRecall.tools, maxRounds: JournalRecall.maxRounds,
                    briefing: intent.map { RecallIntentReader.briefing($0, folders: folders) },
                    runTool: { name, input in
                        await MainActor.run {
                            // 検索の前に、発言から読み取った期間で絞る。空振りしたら全期間に広げる。
                            JournalRecall.run(tool: name, input: input,
                                              entries: (try? store.liveNotes()) ?? [], intent: intent)
                        }
                    },
                    shouldContinue: {
                        await MainActor.run { entitlement.exhaustedBudget(in: store) == nil }
                    })
                for try await event in events {
                    switch event {
                    case .text(let chunk):
                        recallStatus = nil
                        streamingText += chunk
                    case .toolUse(let name, let input):
                        recallStatus = JournalRecall.status(tool: name, input: input)
                    }
                }
            } else {
                for try await chunk in client.streamText(system: Self.system(folders: folders), turns: turns) {
                    streamingText += chunk
                }
            }
            let reply = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
            streamingText = ""
            guard !reply.isEmpty else { return }
            let message = try store.appendMessage(sessionID: sessionID, role: .assistant, content: reply)
            messages.append(message)
        } catch ClaudeClient.Failure.needsPro {
            streamingText = ""
            if chatFeature.monthlyFreeLimit > 0 {
                try? store.syncUsage(chatFeature, used: chatFeature.monthlyFreeLimit)
            }
            showPaywall(.aiChat)
        } catch {
            streamingText = ""
            errorMessage = error.localizedDescription
        }
    }

    /// 検索意図の読み取り。AI が形を守らなかったときは nil にして、意図なしで返答を続ける
    /// （そのときは返答側の AI が自分の判断で探す）。課金や上限のエラーはそのまま上に投げる。
    private func readRecallIntent(_ utterance: String, client: ClaudeClient,
                                  folders: [Node]) async throws -> RecallIntent? {
        do {
            return try await RecallIntentReader(client: client).read(utterance: utterance, folders: folders)
        } catch ClaudeClient.Failure.noToolCall, ClaudeClient.Failure.malformedResponse {
            return nil
        } catch is DecodingError {
            return nil
        }
    }

    /// 対話が使えなかったとき。Paywall を出さない画面では、返事が無い理由と次の一手を一言で伝える。
    /// オンボーディングは AI の返事が最初の 1 通だけなので、それを受け取った後は「使えない」ではなく次へ促す。
    private func showPaywall(_ feature: ProFeature) {
        if offersPaywall {
            paywall = feature
        } else if messages.contains(where: { $0.role == .assistant }) {
            notice = String(localized: "The free version lets you send 1 message to AI. To keep going, choose a plan. Tap \"Turn into Journal\" to save what you wrote.")
        } else {
            notice = String(localized: "AI replies aren't available right now. You can still save what you wrote as a journal.")
        }
    }

    // MARK: - ジャーナル化

    /// 会話を AI に読ませて案をもらう。確認シートを経由してからコミットする。
    ///
    /// Pro（とトライアル）の機能。オンボーディングの体験だけ 1 回無料（`extractFeature`）。
    /// 「勝手に整理される」体験を一度も見せないまま壁を出すと、何を買うのか分からないため。
    /// 使い切ったら Paywall、AI が使えない状態なら自分の言葉のまま案にする。
    func extractJournal(store: Store, entitlement: Entitlement) async {
        let unsaved = unsavedMessages
        guard unsaved.contains(where: { $0.role == .user }) else { return }
        notice = nil

        let access = entitlement.access(to: extractFeature, in: store)
        guard access.isAllowed else {
            if offersPaywall {
                paywall = .journalExtract
            } else {
                draftFromOwnWords()
            }
            return
        }
        // 上限に当たっているときは止めるのではなく、自分の言葉のまま案にする。
        // 記録そのものは AI の都合で止めない。
        guard entitlement.exhaustedBudget(in: store) == nil,
              let client = entitlement.client(meter: store, for: extractFeature) else {
            draftFromOwnWords()
            return
        }

        isExtracting = true
        defer { isExtracting = false }

        do {
            let extractor = JournalExtractor(client: client)
            let proposal = try await extractor.extract(from: unsaved, tree: try store.allNodes())
            // 候補があればチャットの中で尋ねる。無ければ確認シートで選んでもらう。
            if proposal.destinations.isEmpty {
                draft = proposal
            } else {
                pendingSave = proposal
            }
            // 通信が成功したときだけ数える。失敗した呼び出しで無料枠を減らさない。
            // サーバ経由のときは `onFreeQuota` が正しい回数で上書きする。
            if access.consumesFreeQuota {
                try store.consume(extractFeature)
            }
        } catch ClaudeClient.Failure.needsPro {
            // サーバが「無料枠を使い切った」と言っている（アプリの数えが古い）。
            try? store.syncUsage(extractFeature, used: extractFeature.monthlyFreeLimit)
            if offersPaywall {
                paywall = .journalExtract
            } else {
                draftFromOwnWords()
            }
        } catch ClaudeClient.Failure.noToolCall {
            // AI が道具を呼ばず地の文で答えた。記録は AI の都合で止めないので、自分の言葉のまま案にする。
            draftFromOwnWords()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 無料: 自分の発言をそのままジャーナル案にする。分類は自分で選ぶ。
    func draftFromOwnWords() {
        let mine = unsavedMessages.filter { $0.role == .user }.map(\.content)
        guard !mine.isEmpty else { return }
        let body = mine.joined(separator: "\n\n")
        let title = mine.last.map { String($0.prefix(24)) } ?? String(localized: "Today's journal")
        draft = JournalDraft(title: title, body: body, layer: .journal,
                             nodeCode: "", para: .areas, suggestedPath: "")
    }

    // MARK: - 保存先の確認（チャットの中）

    /// 候補のボタンが押された。
    func save(to destination: SaveDestination, store: Store) {
        guard let pending = pendingSave else { return }
        commit(pending.applying(destination), store: store)
    }

    /// 「別の場所を選ぶ・内容を直す」。確認シートに引き継ぐ。
    func editPendingSave() {
        guard let pending = pendingSave else { return }
        pendingSave = nil
        draft = pending
    }

    func cancelPendingSave() {
        pendingSave = nil
        notice = String(localized: "Not saved. You can save again anytime.")
    }

    /// 文字で打たれた返事。名前が合えばそこへ、決められなければ推測せずに聞き返す。
    private func answerSaveQuestion(_ text: String, store: Store) {
        guard let pending = pendingSave else { return }
        let folders = JournalExtractor.candidateNodes(from: (try? store.allNodes()) ?? [])
        if let destination = JournalExtractor.resolveReply(
            text, destinations: pending.destinations, folders: folders) {
            commit(pending.applying(destination), store: store)
        } else if JournalExtractor.isCancelReply(text) {
            cancelPendingSave()
        } else {
            notice = String(localized: "Couldn't tell which folder. Tap a candidate, or choose another place.")
        }
    }

    func commit(_ draft: JournalDraft, store: Store) {
        do {
            let saved = try store.commit(draft)
            // 会話とノートを繋いでおくと、生ログの自動削除から守られる。
            // 次のジャーナル化はここより後の会話だけを読む。
            if let index = messages.indices.last {
                try store.linkMessage(messages[index].id, toNote: saved.note.id)
                messages[index].noteID = saved.note.id
            }
            try store.reloadRoots()
            self.draft = nil
            pendingSave = nil
            lastSavedPath = saved.node.path
            notice = String(localized: "Saved to \(saved.node.path)/\(draft.layer.directoryName)/")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
