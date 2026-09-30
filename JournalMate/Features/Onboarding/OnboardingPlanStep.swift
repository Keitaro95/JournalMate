import SwiftUI

/// オンボーディングの最後のプラン選択。体験の直後に出す。
///
/// **7 日間無料トライアル / Pro / Max** から選んでから本編に入る。中身は設定の「プランを変更」と同じ
/// `PlanChooser`。トライアルを使い切った端末だけは、記録だけの無料プランでも始められる。
struct OnboardingPlanStep: View {

    let onFinish: () -> Void

    var body: some View {
        PlanChooser(context: .onboarding, onFinish: onFinish)
    }
}
