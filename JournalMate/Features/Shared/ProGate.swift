import SwiftUI

/// 無料プランで、AI の入力欄を「見えるけれど触れない」にする（書くことは無料なので、使うのは AI の機能だけ）。
/// 触った瞬間に Paywall を出す。入力欄を無効にするだけだと、なぜ使えないのかが分からないため。
///
/// 契約中とトライアル中（`Entitlement.isPro`）は何もしない。
/// ツールバーのボタンには重ねられないので、そちらは各画面の動作の中で同じ判定をする。
struct ProGate: ViewModifier {

    @Environment(Entitlement.self) private var entitlement

    let feature: ProFeature

    @State private var isShowingPaywall = false

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(entitlement.isPro)
            .overlay {
                if !entitlement.isPro {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { isShowingPaywall = true }
                        .accessibilityElement()
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(feature.title)
                        .accessibilityHint(Text("Requires a plan"))
                }
            }
            .sheet(isPresented: $isShowingPaywall) {
                PaywallSheet(feature: feature)
            }
    }
}

extension View {
    /// 無料プランでは触った瞬間に `feature` の Paywall を出す。
    func proGate(_ feature: ProFeature) -> some View {
        modifier(ProGate(feature: feature))
    }
}
