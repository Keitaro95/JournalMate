import SwiftUI

/// プライバシーポリシー・利用規約などの公開ページ（`docs/` を ai-swift.com に置いたもの）。
enum LegalLinks {
    static let privacyPolicy = URL(string: "https://ai-swift.com/journal-mate/privacy")!
    static let termsOfUse = URL(string: "https://ai-swift.com/journal-mate/terms")!
    /// Apple の標準 EULA（App Store Connect で独自 EULA を設定しない限りこれが適用される）。
    static let appleEULA = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let tokushoho = URL(string: "https://ai-swift.com/journal-mate/tokushoho")!
    static let contact = URL(string: "https://ai-swift.com/journal-mate/contact")!
}

/// AI に内容を送ることへの同意。オンボーディング・設定・Paywall で同じものを出す。
///
/// App Review 5.1.2(i): 個人データを第三者の AI に渡すなら、**何を・誰に**送るかを示し、
/// 送る前に明示的な許可を取る。既定は「同意しない」。
struct AIConsentSection: View {

    @Environment(Entitlement.self) private var entitlement

    private static let whatIsSent: LocalizedStringKey = """
        When you use AI features (chat, journal extraction, sorting, reviews, lesson generation, and setup suggestions), \
        the text involved (what you write, the target memos, and folder names) is sent to Anthropic's Claude API. \
        With a subscription or the free tier, it goes through our relay server, which does not store the content. \
        Anthropic does not use data sent through the API to train its models.
        """

    private static let whenOff: LocalizedStringKey = """
        While this is off, nothing is sent from any screen. Journaling, the calendar, folders, and export keep working. \
        You can change this in Settings at any time.
        """

    var body: some View {
        Section {
            Toggle("Send Content for AI Features", isOn: Binding(
                get: { entitlement.hasAIConsent },
                set: { entitlement.setAIConsent($0) }))
        } header: {
            Text("Sending Data to AI")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.whatIsSent)
                Text(Self.whenOff)
                Link("Privacy Policy", destination: LegalLinks.privacyPolicy)
            }
        }
    }
}

/// 課金画面・設定の末尾に置くリンク。自動更新サブスクリプションでは
/// アプリ内に利用規約とプライバシーポリシーへの導線が必須（App Review 3.1.2）。
struct LegalLinksSection: View {
    var body: some View {
        Section {
            Link("Privacy Policy", destination: LegalLinks.privacyPolicy)
            Link("Terms of Use", destination: LegalLinks.termsOfUse)
        }
    }
}
