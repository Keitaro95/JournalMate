import SwiftUI
import UniformTypeIdentifiers

struct SettingsScreen: View {

    @Environment(Store.self) private var store
    @Environment(Entitlement.self) private var entitlement
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(\.openURL) private var openURL

    @State private var export: ExportedVault?
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var showsPlans = false
    @State private var showsIntro = false
    @State private var isPickingBackup = false
    @State private var pendingRestore: URL?
    @State private var isRestoring = false
    @State private var restoredCount: Int?
    @State private var copiedUserID = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // ただの表記。青にするとボタンに見えるので、押せる「Change Plan」とは色を分ける。
                    LabeledContent("Plan") {
                        Text(planLabel)
                            .foregroundStyle(.primary)
                    }

                    if let planDate {
                        LabeledContent(planDate.label) {
                            Text(planDate.date.formatted(date: .long, time: .omitted))
                                .foregroundStyle(.primary)
                        }
                    }

                    // トライアル・Pro・Max の切り替えはここから（オンボーディングと同じ画面）。
                    Button("Change Plan") { showsPlans = true }

                    if !entitlement.isSubscribed {
                        Button("Restore Purchases") {
                            Task {
                                if await subscriptions.restore() == false {
                                    errorMessage = subscriptions.errorMessage
                                        ?? String(localized: "No purchases to restore were found.")
                                    subscriptions.errorMessage = nil
                                }
                            }
                        }
                        .disabled(!subscriptions.isAvailable || subscriptions.isPurchasing)
                    }

                    if let budget = try? store.dailyBudget(limit: entitlement.dailyLimit), budget.used > 0 {
                        LabeledContent("AI usage today") {
                            Text(entitlement.isMetered
                                 ? "\(budget.used / 1_000)k / \(budget.limit / 1_000)k"
                                 : "\(budget.used / 1_000)k")
                                .appFont(.body, monospacedDigits: true)
                                .foregroundStyle(budget.canStart ? .secondary : Color.orange)
                        }
                    }
                } footer: {
                    if entitlement.paidPlan == .max {
                        Text("All AI features are available with Claude Opus. There are daily and monthly usage limits, twice those of Pro.")
                    } else if entitlement.paidPlan == .pro {
                        Text("All AI features are available with Claude Sonnet. There are daily and monthly usage limits. If you reach them often, Max offers twice the usage.")
                    } else if entitlement.usesTrial, let ends = entitlement.trialEndsAt {
                        Text("Free trial: every feature is available, with AI powered by Claude Haiku, until \(ends.formatted(date: .abbreviated, time: .shortened)). There is a daily usage limit. Afterward, AI needs Pro or Max. You won't be charged, and writing journals, looking back in Calendar, and exporting stay free.")
                    } else if entitlement.isPro {
                        Text("All AI features are available. There is a daily usage limit, but normal use won't reach it.")
                    } else {
                        Text("Without a plan, writing journals, looking back in Calendar and Folders, and exporting stay free forever. AI chat needs a plan.")
                    }
                }

                AIConsentSection()

                Section {
                    NavigationLink {
                        MemoImportScreen()
                    } label: {
                        Label("Import Memos", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("You can import memos from the Notes app or Obsidian into the inbox as raw data, all at once.")
                }

                Section {
                    Button {
                        Task { await exportVault() }
                    } label: {
                        if isExporting {
                            HStack { ProgressView(); Text("Exporting…") }
                        } else {
                            Label("Export Backup (.zip)", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(isExporting || isRestoring)

                    Button {
                        isPickingBackup = true
                    } label: {
                        if isRestoring {
                            HStack { ProgressView(); Text("Restoring…") }
                        } else {
                            Label("Restore from Backup", systemImage: "arrow.counterclockwise")
                        }
                    }
                    .disabled(isExporting || isRestoring)
                } header: {
                    Text("Backup")
                } footer: {
                    Text("""
                        Your journals are stored only on this device. **Deleting the app deletes all of them**, and they can't be recovered.

                        The exported .zip holds your records as .md files in a folder hierarchy (ready for Obsidian), plus restore data for this app. Save it to the Files app or iCloud Drive. After reinstalling, choose that .zip with “Restore from Backup” to bring back your folders and journals as they were. Restoring replaces what's currently in the app. Chat history isn't included in backups.
                        """)
                }

                Section {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        HStack {
                            Text("Language")
                            Spacer()
                            Text(currentLanguageName)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.forward.app")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    Text("Available in Japanese or English. Choose your preferred language in Settings > General > Language & Region.")
                }

                Section("About This Design") {
                    Button("About This App") { showsIntro = true }
                        .foregroundStyle(.primary)
                    NavigationLink("How the Folder Structure Works") { StructureExplainer() }
                }

                Section {
                    Link("Privacy Policy", destination: LegalLinks.privacyPolicy)
                    Link("Terms of Use", destination: LegalLinks.termsOfUse)
                    Link("Terms of Use (EULA)", destination: LegalLinks.appleEULA)
                    Link("Legal Notice (Specified Commercial Transactions Act)", destination: LegalLinks.tokushoho)
                    Link("Contact Us", destination: LegalLinks.contact)

                    // RevenueCat の appUserID と同じ値。問い合わせや、プランを手で付与するときに
                    // ダッシュボードの Customers でこの ID を引く。
                    Button {
                        UIPasteboard.general.string = entitlement.appUserID
                        copiedUserID = true
                    } label: {
                        LabeledContent("User ID") {
                            Text(copiedUserID ? String(localized: "Copied") : entitlement.appUserID)
                                .appFont(.caption1, monospacedDigits: true)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Support")
                } footer: {
                    Text("Tap to copy your user ID. Include it when you contact us.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $export) { export in
                ShareSheet(items: [export.url])
            }
            .sheet(isPresented: $showsPlans) {
                PlanChooser(context: .settings) { showsPlans = false }
            }
            // 初回起動の説明スライドをそのまま見返す。
            .fullScreenCover(isPresented: $showsIntro) {
                OnboardingIntroPages(finishTitle: "Close", skipTitle: "Close") { showsIntro = false }
            }
            .fileImporter(isPresented: $isPickingBackup, allowedContentTypes: [.zip, .folder]) { result in
                switch result {
                case .success(let url): pendingRestore = url
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .confirmationDialog("Replace the current records with this backup?",
                                isPresented: .constant(pendingRestore != nil),
                                titleVisibility: .visible) {
                Button("Restore", role: .destructive) {
                    if let url = pendingRestore { Task { await restoreVault(from: url) } }
                    pendingRestore = nil
                }
                Button("Cancel", role: .cancel) { pendingRestore = nil }
            } message: {
                Text("Folders and journals in the app are replaced with the contents of the backup. Anything written after the backup was made will be lost. Chat history on this device is kept.")
            }
            .alert("Restored", isPresented: .constant(restoredCount != nil)) {
                Button("OK") { restoredCount = nil }
            } message: {
                Text("Restored \(restoredCount ?? 0) notes.")
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// 「更新日」か「終了日」。トライアルは自動で課金されないので、いつも「終了日」と書く。
    private var planDate: (label: LocalizedStringKey, date: Date)? {
        if entitlement.isSubscribed, let renewsAt = entitlement.renewsAt {
            return (entitlement.willRenew ? "Renews On" : "Ends On", renewsAt)
        }
        if entitlement.usesTrial, let ends = entitlement.trialEndsAt {
            return ("Ends On", ends)
        }
        return nil
    }

    private var planLabel: String {
        if let paidPlan = entitlement.paidPlan { return paidPlan.title }
        if entitlement.usesTrial { return String(localized: "Trial") }
        return String(localized: "Free")
    }

    /// アプリが実際に表示している言語を、その言語自身の表記で返す（例: 「日本語」「English」）。
    /// 言語名は翻訳しないので `String` のまま渡す。
    private var currentLanguageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: code).localizedString(forIdentifier: code) ?? code
    }

    private func exportVault() async {
        isExporting = true
        defer { isExporting = false }
        do {
            export = ExportedVault(url: try VaultExporter.exportZip(from: store))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreVault(from url: URL) async {
        isRestoring = true
        defer { isRestoring = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            // zip の展開は重いのでメインから外す。置き換えだけ Store（MainActor）で行う。
            let backup = try await Task.detached { try VaultExporter.extractBackup(from: url) }.value
            defer { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }
            restoredCount = try store.restore(fromBackup: backup)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// `sheet(item:)` に渡すための入れ物。URL に直接 Identifiable を足さない。
private struct ExportedVault: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// フォルダ（PARA）と 3 種類のノートの説明。
/// 番号（node.code）は画面に出さないので、ここでも説明しない。
private struct StructureExplainer: View {
    var body: some View {
        List {
            Section {
                ForEach(Para.allCases) { para in
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(para.displayTitle)
                                .appFont(.subheadline, weight: .semibold)
                            if para != .journal {
                                Text(para.subtitle)
                                    .appFont(.caption1)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: para.symbol)
                            .foregroundStyle(para.tint)
                    }
                }
            } header: {
                Text("Folders")
            } footer: {
                Text("Sort by how involved you are right now, not by topic or field.")
            }

            Section("Three Kinds of Notes") {
                ForEach(Layer.allCases) { layer in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(layer.title)
                            .appFont(.subheadline, weight: .semibold)
                        Text(layer.summary)
                            .appFont(.caption1)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("How It Works")
        .navigationBarTitleDisplayMode(.inline)
    }
}
