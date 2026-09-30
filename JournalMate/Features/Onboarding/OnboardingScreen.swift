import SwiftUI

/// 初回起動。**説明 → 体験 → プラン選択**の 3 段。
///
/// 課金の話は、AI と話してジャーナルが 1 本できるところまで見せてからにする。
/// 何を買うのか分からないまま壁を出しても、選ぶ理由がないため。
struct OnboardingScreen: View {

    @Binding var isComplete: Bool

    private enum Step {
        case intro, tryJournal, plans
    }

    @State private var step: Step = .intro

    var body: some View {
        Group {
            switch step {
            case .intro:
                OnboardingIntroPages { step = .tryJournal }
            case .tryJournal:
                OnboardingJournalStep { step = .plans }
            case .plans:
                OnboardingPlanStep { isComplete = true }
            }
        }
        .animation(.default, value: step)
        .interactiveDismissDisabled()
    }
}
