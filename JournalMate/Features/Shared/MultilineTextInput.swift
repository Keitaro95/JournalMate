import SwiftUI
import UIKit

/// SwiftUI の複数行 TextField/TextEditor で発生するキーボード制約警告を避けるための入力欄。
struct MultilineTextInput: View {

    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 44
    var maxHeight: CGFloat?
    var isScrollEnabled = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty && !placeholder.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }

            TextViewRepresentable(
                text: $text,
                minHeight: minHeight,
                maxHeight: maxHeight,
                isScrollEnabled: isScrollEnabled)
        }
        .frame(minHeight: minHeight)
    }
}

private struct TextViewRepresentable: UIViewRepresentable {

    @Binding var text: String
    let minHeight: CGFloat
    let maxHeight: CGFloat?
    let isScrollEnabled: Bool

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.isScrollEnabled = isScrollEnabled
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let assistantItem = textView.inputAssistantItem
        assistantItem.leadingBarButtonGroups = []
        assistantItem.trailingBarButtonGroups = []

        applyFont(to: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }

        textView.isScrollEnabled = shouldScroll(textView)
        applyFont(to: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        let measuredSize = uiView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        let height = clampedHeight(measuredSize.height)
        return CGSize(width: width, height: height)
    }

    private func shouldScroll(_ textView: UITextView) -> Bool {
        guard maxHeight != nil else { return isScrollEnabled }
        return textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: CGFloat.greatestFiniteMagnitude)).height > clampedHeight(textView.contentSize.height)
    }

    private func clampedHeight(_ height: CGFloat) -> CGFloat {
        let minimumHeight = max(height, minHeight)
        guard let maxHeight else { return minimumHeight }
        return min(minimumHeight, maxHeight)
    }

    private func applyFont(to textView: UITextView) {
        // 標準サイズで作り、adjustsFontForContentSizeCategory が効くよう UIFontMetrics で拡縮させる。
        let base = AppFont.uiFont(.body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}
