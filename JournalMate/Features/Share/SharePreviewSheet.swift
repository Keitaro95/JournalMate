import SwiftUI
import UIKit

/// 外へ出すリンク。
enum AppLinks {
    /// App Store のページ。国の部分（/jp/）を付けないと、開いた人の国のストアに飛ぶ。
    /// 共有から何人入れたかを数えたくなったら、App Store Connect の「App 分析 > キャンペーン」で
    /// `pt`（プロバイダトークン）付きのリンクを作って差し替える。
    static let appStore = URL(string: "https://apps.apple.com/app/journalmate/id6816923147")!
}

/// 共有の前に、画像がどう見えるかを本人に確かめてもらう。
/// ジャーナルは私的なものなので、押した瞬間にそのまま出ていく作りにはしない。
struct SharePreviewSheet: View {

    let content: ShareCardContent

    @Environment(\.dismiss) private var dismiss
    /// 画像の下のアプリ名と、X などに渡す文面・リンク。最後に選んだものを覚えておく。
    @AppStorage("shareIncludesAppName") private var includesAppName = true

    @State private var images: [UIImage] = []
    @State private var isPresentingActivity = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TabView {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(.rect(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 36)
                    }
                }
                .tabViewStyle(.page)
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .overlay {
                    if images.isEmpty { ProgressView() }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Include app name", isOn: $includesAppName)
                        .appFont(.subheadline)
                    Label("The shared image shows your journal exactly as it is.",
                          systemImage: "eye")
                        .appFont(.caption1)
                        .foregroundStyle(.secondary)
                    Button {
                        isPresentingActivity = true
                    } label: {
                        Text("Share")
                            .appFont(.body, weight: .semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(images.isEmpty)
                    .accessibilityIdentifier("SharePreview.Share")
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .background(Color(.secondarySystemBackground))
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: includesAppName) {
                images = ShareCardRenderer.render(content, includesAppName: includesAppName)
            }
            .sheet(isPresented: $isPresentingActivity) {
                ActivitySheet(items: activityItems) { completed in
                    isPresentingActivity = false
                    if completed { dismiss() }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    /// Instagram は文面を受け取らないので、名前が届くのは画像の下の 1 行だけ。
    /// X などには文面とリンクも渡す（投稿の前に本人が書き換えられる）。
    private var activityItems: [Any] {
        var items: [Any] = images
        if includesAppName {
            let text = String(localized: "Journaled with JournalMate! #JournalMate")
            items.append(ShareTextItem(text: "\(text)\n\(AppLinks.appStore.absoluteString)"))
        }
        return items
    }
}

/// 文面を受け取れない送り先（Instagram・写真に保存）には文面を渡さない。
/// 画像と文字が混ざっていると、送り先によっては画像まで落とされることがあるため。
private final class ShareTextItem: NSObject, UIActivityItemSource {
    let text: String

    init(text: String) {
        self.text = text
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        text
    }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        guard let activityType else { return text }
        if activityType == .saveToCameraRoll
            || activityType.rawValue.localizedCaseInsensitiveContains("instagram") {
            return nil
        }
        return text
    }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in onComplete(completed) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
