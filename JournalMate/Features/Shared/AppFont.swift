import SwiftUI
import UIKit

/// アプリ共通の書体。欧文は SF Pro（システムフォント）、和文は Hiragino Sans。
/// システムフォントの和文フォールバックは端末の言語設定次第で PingFang になることがあるため、
/// カスケードリストで Hiragino Sans を明示する。
enum AppFont {

    static func uiFont(
        _ style: UIFont.TextStyle,
        weight: UIFont.Weight? = nil,
        monospacedDigits: Bool = false,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        let size = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
        let weight = weight ?? (style == .headline ? .semibold : .regular)
        let base = monospacedDigits
            ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        return withJapaneseFallback(base, weight: weight)
    }

    static func withJapaneseFallback(_ font: UIFont, weight: UIFont.Weight) -> UIFont {
        let japanese = UIFontDescriptor(name: hiraginoName(for: weight), size: font.pointSize)
        let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: [japanese]])
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    /// iOS に入っている Hiragino Sans は W3 / W6 / W7 の 3 ウェイト。
    private static func hiraginoName(for weight: UIFont.Weight) -> String {
        switch weight {
        case ..<UIFont.Weight.semibold: "HiraginoSans-W3"
        case ..<UIFont.Weight.heavy: "HiraginoSans-W6"
        default: "HiraginoSans-W7"
        }
    }

    /// ナビゲーションバー・タブバーなど UIKit 側で描かれる文字にも同じ書体を当てる。
    @MainActor
    static func applyToSystemBars() {
        let navigation = UINavigationBar.appearance()
        navigation.titleTextAttributes = [.font: uiFont(.headline)]
        navigation.largeTitleTextAttributes = [.font: uiFont(.largeTitle, weight: .bold)]

        let tabItem = UITabBarItem.appearance()
        for state in [UIControl.State.normal, .selected] {
            tabItem.setTitleTextAttributes([.font: uiFont(.caption2, weight: .medium)], for: state)
        }
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let style: UIFont.TextStyle
    let weight: UIFont.Weight?
    let monospacedDigits: Bool

    func body(content: Content) -> some View {
        // Font(UIFont) は Dynamic Type に追従しないので、文字サイズ設定から毎回作り直す。
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        content.font(Font(AppFont.uiFont(
            style, weight: weight, monospacedDigits: monospacedDigits, compatibleWith: traits)))
    }
}

extension View {
    /// `.font(.caption.weight(.semibold))` の代わりに使う。
    func appFont(
        _ style: UIFont.TextStyle = .body,
        weight: UIFont.Weight? = nil,
        monospacedDigits: Bool = false
    ) -> some View {
        modifier(AppFontModifier(style: style, weight: weight, monospacedDigits: monospacedDigits))
    }
}
