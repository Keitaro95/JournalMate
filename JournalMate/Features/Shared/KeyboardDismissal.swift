import SwiftUI
import UIKit

extension View {
    /// 入力欄以外をタップしたらキーボードを閉じる。ウィンドウに 1 つだけ付ければ、
    /// シートや fullScreenCover の中も含めて全画面に効く。
    func dismissesKeyboardOnTapOutside() -> some View {
        background(KeyboardDismissInstaller())
    }

    /// この範囲のタップではキーボードを閉じない（チャットの送信ボタンなど、
    /// 続けて打つのが自然な場所に付ける）。
    func keepsKeyboardOnTap() -> some View {
        background(KeyboardKeepZone())
    }
}

private struct KeyboardDismissInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window,
                  !(window.gestureRecognizers ?? []).contains(where: { $0 is KeyboardDismissTapRecognizer })
            else { return }
            window.addGestureRecognizer(KeyboardDismissTapRecognizer())
        }
    }
}

private final class KeyboardDismissTapRecognizer: UITapGestureRecognizer, UIGestureRecognizerDelegate {

    init() {
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(handleTap))
        // 下にあるボタンやリストのタップはそのまま通す。
        cancelsTouchesInView = false
        delegate = self
    }

    @objc private func handleTap() {
        view?.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 別の入力欄へ移るタップで一度閉じるとキーボードがちらつく。
        var hit = touch.view
        while let view = hit {
            if view is UITextView || view is UITextField { return false }
            hit = view.superview
        }
        return !KeyboardKeepZone.contains(touch)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

private struct KeyboardKeepZone: UIViewRepresentable {
    func makeUIView(context: Context) -> ZoneView { ZoneView() }
    func updateUIView(_ uiView: ZoneView, context: Context) {}

    /// SwiftUI の中身はヒットテストでは UIView として見えないので、
    /// 背景に置いた UIView の矩形でタップ位置を判定する。
    static func contains(_ touch: UITouch) -> Bool {
        ZoneView.live.allObjects.contains { zone in
            zone.window != nil && zone.bounds.contains(touch.location(in: zone))
        }
    }

    final class ZoneView: UIView {
        static let live = NSHashTable<ZoneView>.weakObjects()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { Self.live.add(self) } else { Self.live.remove(self) }
        }
    }
}
