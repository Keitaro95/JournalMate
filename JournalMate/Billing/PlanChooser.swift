import StoreKit
import SwiftUI

/// プランの説明と選択。**オンボーディングの最後**と**設定の「プランを変更」**の両方で使う。
///
/// 並びは **7 日間無料トライアル → Pro → Max**。Pro と Max は上の切り替えで月額 / 年額を選ぶ。
/// 課金（RevenueCat）がまだ繋がっていなくても、プランの中身と価格は必ず見せる。
/// 空の画面を出すと、何が買えるのか分からないまま先へ進むことになるため。
/// そのときは購入ボタンだけを止め、理由を添える。
struct PlanChooser: View {

    enum Context {
        /// 初回起動。閉じるボタンは出さない。トライアルを使えない端末には「無料で続ける」を出す。
        case onboarding
        /// 設定から。閉じるボタンと、App Store の購読管理（解約・ダウングレード）を出す。
        case settings
    }

    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(Entitlement.self) private var entitlement

    let context: Context
    /// トライアルの開始・購入が済んだとき、または閉じたとき。
    let onFinish: () -> Void

    private enum Choice: Hashable {
        case trial
        case paid(PaidPlan)
    }

    @State private var choice: Choice?
    @State private var isAnnual = false
    @State private var isStartingTrial = false
    @State private var showsManageSubscriptions = false
    /// トライアルを始められなかった理由。
    @State private var trialError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header

                    trialCard

                    Picker("Billing Period", selection: $isAnnual) {
                        Text("Monthly").tag(false)
                        Text("Annual").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 8)

                    paidCard(.pro)
                    paidCard(.max)

                    includedFeatures
                    finePrint
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) { callToAction }
            .navigationTitle(context == .settings ? "Change Plan" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if context == .settings {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", action: onFinish)
                    }
                }
            }
            .task {
                if choice == nil { choice = defaultChoice }
                await subscriptions.refresh()
                await subscriptions.loadPlans()
            }
            // 購入・復元・アップグレードのどれでも、プランが変わったら閉じる。
            .onChange(of: entitlement.paidPlan) { old, new in
                if new != nil, new != old { onFinish() }
            }
            .manageSubscriptionsSheet(isPresented: $showsManageSubscriptions)
            .alert("Error", isPresented: .constant(subscriptions.errorMessage != nil)) {
                Button("OK") { subscriptions.errorMessage = nil }
            } message: {
                Text(subscriptions.errorMessage ?? "")
            }
            .alert("Error", isPresented: .constant(trialError != nil)) {
                Button("Try Again") {
                    trialError = nil
                    Task { await confirm() }
                }
                if context == .onboarding {
                    // 初回起動で止めない。プランが無くても書く・振り返る・書き出すはできるので、そのまま先へ進める。
                    Button("Continue for Free", role: .cancel) {
                        trialError = nil
                        onFinish()
                    }
                } else {
                    Button("Close", role: .cancel) { trialError = nil }
                }
            } message: {
                Text(trialError ?? "")
            }
        }
    }

    // MARK: - 見出し

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose Your Plan")
                .appFont(.title2, weight: .bold)
            Text("Start with a free 7-day trial, or choose Pro or Max. You can change your plan anytime in Settings.")
                .appFont(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }

    // MARK: - カード

    private var trialCard: some View {
        PlanCard(
            symbol: "gift",
            title: String(localized: "7-Day Free Trial"),
            summary: String(localized: "Try every AI feature free. No payment needed, and it ends on its own."),
            details: [
                String(localized: "Claude Haiku"),
                String(localized: "Up to a small daily limit"),
            ],
            price: String(localized: "Free"),
            badge: trialBadge,
            isSelected: choice == .trial,
            isEnabled: entitlement.canStartTrial
        ) { choice = .trial }
    }

    private var trialBadge: PlanCard.Badge? {
        if entitlement.usesTrial, let ends = entitlement.trialEndsAt {
            return .current(String(localized: "Until \(ends.formatted(date: .abbreviated, time: .omitted))"))
        }
        if !entitlement.canStartTrial, !entitlement.isSubscribed {
            return .note(String(localized: "Already used"))
        }
        return nil
    }

    private func paidCard(_ tier: PaidPlan) -> some View {
        PlanCard(
            symbol: tier == .max ? "bolt.fill" : "sparkles",
            title: tier.title,
            summary: tier == .max
                ? String(localized: "Claude Opus, the most capable model, with twice the usage of Pro")
                : String(localized: "Every AI feature, powered by Claude Sonnet"),
            details: tier == .max
                ? [String(localized: "Claude Opus"), String(localized: "Twice the daily and monthly usage of Pro")]
                : [String(localized: "Claude Sonnet"), String(localized: "Daily and monthly usage limits")],
            price: priceText(tier),
            badge: entitlement.paidPlan == tier ? .current(nil)
                : tier == .pro && !entitlement.isSubscribed ? .recommended
                : nil,
            isSelected: choice == .paid(tier),
            isEnabled: true
        ) { choice = .paid(tier) }
    }

    /// App Store の価格が取れていればそれを、取れなければ参考価格（円）を出す。
    private func priceText(_ tier: PaidPlan) -> String {
        let price = storePlan(tier)?.price ?? tier.referencePrice(isAnnual: isAnnual)
        return isAnnual ? String(localized: "\(price) / year") : String(localized: "\(price) / month")
    }

    private func storePlan(_ tier: PaidPlan) -> SubscriptionService.Plan? {
        subscriptions.plans.first { $0.tier == tier && $0.isAnnual == isAnnual }
    }

    // MARK: - 説明

    private var includedFeatures: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Included in Every Plan")
                .appFont(.headline)
            ForEach(ProFeature.allCases.filter(\.isListed), id: \.self) { feature in
                Label {
                    Text(feature.title).appFont(.subheadline)
                } icon: {
                    Image(systemName: feature.symbol).foregroundStyle(Color.accentColor)
                }
            }
            Label {
                Text("Without a plan, writing journals, looking back in Calendar, and exporting stay free forever").appFont(.subheadline)
            } icon: {
                Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
            }
        }
        .padding(.top, 16)
    }

    private var finePrint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("""
                Subscriptions renew automatically unless canceled at least 24 hours before the end of the current period, \
                and renewals are charged to your Apple ID. \
                You can cancel from your App Store subscriptions. \
                The free trial does not require payment and does not renew. \
                With a subscription, the app covers the cost of AI calls.
                """)
            HStack(spacing: 16) {
                if subscriptions.isAvailable {
                    Button("Restore Purchases") {
                        Task { await subscriptions.restore() }
                    }
                    .disabled(subscriptions.isPurchasing)
                }
                if entitlement.isSubscribed {
                    Button("Manage Subscription") { showsManageSubscriptions = true }
                }
            }
            HStack(spacing: 16) {
                Link("Privacy Policy", destination: LegalLinks.privacyPolicy)
                Link("Terms of Use", destination: LegalLinks.termsOfUse)
            }
        }
        .appFont(.caption1)
        .foregroundStyle(.secondary)
        .padding(.top, 16)
    }

    // MARK: - 確定

    private var callToAction: some View {
        VStack(spacing: 8) {
            if case .paid = choice, !subscriptions.isAvailable {
                // 課金が未設定の間（SDK 未追加・キー未設定）。理由の細部は開発者向けなので出さない。
                Text("Subscriptions are not available yet. Start with the free trial for now.")
                    .appFont(.caption1)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await confirm() }
            } label: {
                HStack {
                    if isStartingTrial || subscriptions.isPurchasing { ProgressView() }
                    Text(ctaTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canConfirm)

            // トライアルを使い切った端末でも、AI 以外は全部使える無料プランで始められるようにする。
            if context == .onboarding, !entitlement.canStartTrial, !entitlement.isPro {
                Button("Continue for Free", action: onFinish)
                    .appFont(.subheadline)
            }
        }
        .padding()
        .background(.bar)
    }

    private var ctaTitle: LocalizedStringKey {
        switch choice {
        case .trial, nil:
            return "Start 7-Day Free Trial"
        case .paid(let tier):
            if entitlement.isSubscribed { return "Change to \(tier.title)" }
            return "Subscribe to \(tier.title)"
        }
    }

    private var canConfirm: Bool {
        guard !isStartingTrial, !subscriptions.isPurchasing else { return false }
        switch choice {
        case .trial: return entitlement.canStartTrial
        case .paid(let tier): return subscriptions.isAvailable && storePlan(tier) != nil
        case nil: return false
        }
    }

    /// 最初に選んでおくもの。トライアルが使えればそれ、Pro の人には Max、それ以外は Pro。
    private var defaultChoice: Choice {
        if entitlement.canStartTrial { return .trial }
        return entitlement.paidPlan == .pro ? .paid(.max) : .paid(.pro)
    }

    private func confirm() async {
        switch choice {
        case .trial:
            isStartingTrial = true
            defer { isStartingTrial = false }
            do {
                try await entitlement.startTrial()
                onFinish()
            } catch {
                trialError = error.localizedDescription
            }
        case .paid(let tier):
            guard let plan = storePlan(tier) else { return }
            // プランが変われば `paidPlan` の変化で閉じる。月額 ↔ 年額の変更は tier が変わらないのでここで閉じる。
            if await subscriptions.purchase(plan) { onFinish() }
        case nil:
            break
        }
    }
}

/// 1 プランぶんのカード。タップで選ぶだけで、確定は下のボタン。
private struct PlanCard: View {

    enum Badge {
        case recommended
        /// 契約中・トライアル中。添え書き（期限など）を付けられる。
        case current(String?)
        /// 使用済みなど、選べない理由。
        case note(String)
    }

    let symbol: String
    let title: String
    let summary: String
    let details: [String]
    let price: String
    let badge: Badge?
    let isSelected: Bool
    let isEnabled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .appFont(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Label(title, systemImage: symbol)
                            .appFont(.body, weight: .semibold)
                        badgeView
                        Spacer(minLength: 8)
                        Text(price)
                            .appFont(.subheadline, weight: .semibold, monospacedDigits: true)
                    }
                    Text(summary)
                        .appFont(.caption1)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(details, id: \.self) { detail in
                            Label(detail, systemImage: "checkmark")
                                .appFont(.caption1)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
            .background(.background, in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                                  lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
    }

    @ViewBuilder
    private var badgeView: some View {
        switch badge {
        case .recommended:
            capsule(String(localized: "Recommended"), color: .accentColor)
        case .current(let note):
            capsule(note.map { String(localized: "Current · \($0)") } ?? String(localized: "Current Plan"),
                    color: .green)
        case .note(let text):
            capsule(text, color: .secondary)
        case nil:
            EmptyView()
        }
    }

    private func capsule(_ text: String, color: Color) -> some View {
        Text(text)
            .appFont(.caption2, weight: .semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}
