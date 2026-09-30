import SwiftUI

/// 説明スライド 6 枚。画面のスクショの代わりに、実物の部品にサンプルデータを入れて描く
/// （言語とダークモードにそのまま追従し、画面を変えても差し替えが要らない）。
///
/// 初回起動のほか、設定 > このアプリの説明 からも開く。そのときはボタンの文言だけ変える。
struct OnboardingIntroPages: View {

    /// 最後のページのボタン。
    var finishTitle: LocalizedStringKey = "Let's Try Journaling"
    /// 右上のボタン。最後のページでは隠す（下のボタンと同じ働きになるため）。
    var skipTitle: LocalizedStringKey = "Skip"
    let onFinish: () -> Void

    private enum Page: Int, CaseIterable {
        case welcome, chat, save, para, calendar, storage

        static var last: Page { allCases[allCases.count - 1] }
    }

    @State private var page: Page = .welcome

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(skipTitle, action: onFinish)
                    .foregroundStyle(.secondary)
                    .opacity(page == .last ? 0 : 1)
            }
            .padding(.horizontal)
            .frame(height: 44)

            TabView(selection: $page) {
                ForEach(Page.allCases, id: \.self) { page in
                    content(for: page)
                        .tag(page)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 48)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if let next = Page(rawValue: page.rawValue + 1) {
                    withAnimation { page = next }
                } else {
                    onFinish()
                }
            } label: {
                Text(page == .last ? finishTitle : "Next")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func content(for page: Page) -> some View {
        switch page {
        case .welcome:
            IntroPage(title: "JournalMate",
                      message: "Just talk, and it becomes that day's journal.") {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 88))
                    .foregroundStyle(.tint)
            }
        case .chat:
            IntroPage(title: "Journaling Happens in Conversation",
                      message: "AI asks one question at a time and draws out what's on your mind. No blank page to face.") {
                ChatMock()
            }
        case .save:
            IntroPage(title: "Organized and Saved for You",
                      message: "AI summarizes the conversation and suggests where it belongs. One tap saves it.") {
                SaveMock()
            }
        case .para:
            IntroPage(title: "Folders Built on PARA",
                      message: "Everyday notes go in Journal; everything else is sorted into Projects, Areas, Resources, and Archives, so you always know where to look.") {
                ParaMock()
            }
        case .calendar:
            IntroPage(title: "Look Back on the Calendar",
                      message: "Every journal lines up by day. See at a glance what you thought and when.") {
                CalendarMock()
            }
        case .storage:
            // 消えてから知るのでは遅いので、始める前に一度だけはっきり伝える。
            IntroPage(title: "Your Journals Live on This iPhone",
                      message: "Records are stored only on this device. Deleting the app deletes every journal. Export a backup from Settings now and then, and you can restore it after reinstalling.") {
                StorageMock()
            }
        }
    }
}

// MARK: - 1 枚の型

/// 上にモック、下に見出しと説明。どのページも同じ配置にして、目の動きを揃える。
private struct IntroPage<Visual: View>: View {

    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder let visual: Visual

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 8)
            visual
                .frame(maxWidth: 360)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            VStack(spacing: 10) {
                Text(title)
                    .appFont(.title2, weight: .bold)
                Text(message)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// モックを載せる台。画面の一部を切り出したように見せる。
private struct MockCard<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: .rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
    }
}

// MARK: - モック

private struct ChatMock: View {

    private var messages: [Message] {
        [
            sample(.assistant, String(localized: "What were you thinking about today?")),
            sample(.user, String(localized: "The team meeting ran long and I couldn't finish my own work.")),
            sample(.assistant, String(localized: "That sounds draining. What took up most of the meeting?")),
            sample(.user, String(localized: "Deciding the release date. I think we could have settled it in advance.")),
        ]
    }

    var body: some View {
        MockCard {
            VStack(spacing: 10) {
                ForEach(messages) { MessageBubble(message: $0) }
            }
            .appFont(.subheadline)
        }
    }
}

private struct SaveMock: View {

    private var draft: JournalDraft {
        JournalDraft(
            title: String(localized: "Deciding things before the meeting"),
            body: String(localized: "The meeting ran long over the release date. Next time, share a draft in advance."),
            layer: .journal,
            nodeCode: "",
            para: .areas,
            suggestedPath: "",
            summary: String(localized: "Today was about how the team runs meetings."),
            destinations: [
                SaveDestination(para: .areas, newPath: String(localized: "Work"),
                                reason: String(localized: "An ongoing responsibility at work")),
            ])
    }

    var body: some View {
        SaveProposalCard(draft: draft, onChoose: { _ in }, onEdit: {}, onCancel: {})
            .appFont(.subheadline)
    }
}

private struct ParaMock: View {

    /// PARA ごとのフォルダの例。
    private func examples(for para: Para) -> [String] {
        switch para {
        case .journal: return []
        case .projects: return [String(localized: "Moving house"), String(localized: "Certification exam")]
        case .areas: return [String(localized: "Work"), String(localized: "Health")]
        case .resources: return [String(localized: "Books"), String(localized: "Cooking")]
        case .archives: return [String(localized: "2025")]
        }
    }

    var body: some View {
        MockCard {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Para.allCases) { para in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: para.symbol)
                                .foregroundStyle(para.tint)
                                .frame(width: 22)
                            Text(para.title).appFont(.subheadline, weight: .semibold)
                            Text(para.subtitle).appFont(.caption1).foregroundStyle(.secondary)
                            Spacer()
                            Text(verbatim: "\(para.leadingDigit)xx")
                                .appFont(.caption1, monospacedDigits: true)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(Array(examples(for: para).enumerated()), id: \.offset) { index, name in
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(name)
                                Spacer()
                                Text(verbatim: "\(para.leadingDigit)\(index + 1)0")
                                    .appFont(.caption2, monospacedDigits: true)
                                    .foregroundStyle(.tertiary)
                            }
                            .appFont(.caption1)
                            .padding(.leading, 30)
                        }
                    }
                }
            }
        }
    }
}

private struct CalendarMock: View {

    /// 印を付ける日（その日にジャーナルがある）。
    private let journalDays: Set<Int> = [2, 3, 5, 8, 9, 10, 12, 15, 16, 17, 19, 22, 23]
    private let today = 23

    private var weekdays: [String] {
        Calendar.current.veryShortStandaloneWeekdaySymbols
    }

    var body: some View {
        VStack(spacing: 12) {
            MockCard {
                VStack(spacing: 8) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 8) {
                        ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                            Text(symbol)
                                .appFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        // 月の頭を 2 日ずらして、実物のカレンダーらしく見せる。
                        ForEach(0..<2, id: \.self) { _ in Color.clear.frame(height: 1) }
                        ForEach(1...28, id: \.self) { day in
                            VStack(spacing: 3) {
                                Text(verbatim: "\(day)")
                                    .appFont(.caption1, weight: day == today ? .bold : .regular)
                                    .foregroundStyle(day == today ? Color.white : .primary)
                                    .frame(width: 24, height: 24)
                                    .background(day == today ? Color.accentColor : .clear, in: .circle)
                                Circle()
                                    .fill(journalDays.contains(day) ? Color.accentColor : .clear)
                                    .frame(width: 4, height: 4)
                            }
                        }
                    }
                }
            }
            MockCard {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: Para.areas.symbol)
                        .foregroundStyle(Para.areas.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Deciding things before the meeting")
                            .appFont(.subheadline, weight: .semibold)
                        Text("The meeting ran long over the release date. Next time, share a draft in advance.")
                            .appFont(.caption1)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

private struct StorageMock: View {

    var body: some View {
        VStack(spacing: 12) {
            MockCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .appFont(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Deleting the app deletes your journals")
                            .appFont(.subheadline, weight: .semibold)
                        Text("Nothing is kept on our servers, so they can't be recovered afterward.")
                            .appFont(.caption1)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            MockCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Settings > Backup")
                        .appFont(.caption1)
                        .foregroundStyle(.secondary)
                    Label("Export Backup (.zip)", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.tint)
                    Divider()
                    Label("Restore from Backup", systemImage: "arrow.counterclockwise")
                        .foregroundStyle(.tint)
                }
                .appFont(.subheadline)
            }
        }
    }
}

private func sample(_ role: Message.Role, _ content: String) -> Message {
    Message(id: UUID().uuidString, sessionID: "", role: role,
            content: content, noteID: nil, createdAt: Date())
}
