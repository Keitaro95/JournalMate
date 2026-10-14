import SwiftUI

/// 課金画面。**どの機能で止まったか**を見出しに出す。
/// 「Pro のご案内」ではなく「受信箱の一括分類は Pro の機能です」と言う方が、
/// ユーザーは自分が今なにを買おうとしているのか分かる。
///
/// 並びは **トライアル（7 日・無料）→ Pro → Max**。トライアルは App Store を通さない独立したプランで、
/// Pro と Max は最初から課金して買える。
///
/// `feature` が nil のときは Max へのアップグレード画面として出す（設定画面から、Pro の契約者向け）。
/// Pro の契約者には Max のプランだけを並べる。
struct PaywallSheet: View {

    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(Entitlement.self) private var entitlement
    @Environment(\.dismiss) private var dismiss

    @State private var isStartingTrial = false

    /// Paywall を出す引き金になった機能。nil なら Max へのアップグレード。
    let feature: ProFeature?

    var body: some View {
        NavigationStack {
            Form {
                if let feature {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(feature.title, systemImage: feature.symbol)
                                .appFont(.headline)
                            Text(feature.summary)
                                .appFont(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } footer: {
                        if feature.monthlyFreeLimit > 0 {
                            Text("Free users can use this up to \(feature.monthlyFreeLimit) times a month. You've used up this month's allowance.")
                        } else if feature == .aiChat {
                            Text("AI chat is available with a plan. The AI reads the journals you've written and gives you summaries and reflections.")
                        } else {
                            Text("This feature needs Pro, Max, or the free trial.")
                        }
                    }
                }

                if !entitlement.isSubscribed {
                    featureList
                }

                Section {
                    if !entitlement.isSubscribed {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Trial")
                                Text("7 days free. Every feature, with AI powered by Claude Haiku")
                                    .appFont(.caption1)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "gift")
                        }
                    }
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pro")
                            Text("Every AI feature, powered by Claude Sonnet")
                                .appFont(.caption1)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "sparkles")
                    }
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Max")
                            Text("Claude Opus, the most capable model, with twice the usage of Pro")
                                .appFont(.caption1)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "bolt.fill")
                    }
                } header: {
                    Text("Plans")
                } footer: {
                    Text("Every plan includes every feature. Max is for people who reach Pro's monthly limit or want to use AI more.")
                }

                if !entitlement.isSubscribed {
                    Section {
                        Label("Without a plan, writing journals, looking back in Calendar, and exporting stay free forever",
                              systemImage: "checkmark.seal")
                            .appFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !entitlement.hasAIConsent {
                    AIConsentSection()
                }

                trialSection

                planSection

                Section {
                    Button("Restore Purchases") {
                        Task {
                            if await subscriptions.restore() { dismiss() }
                        }
                    }
                    .disabled(!subscriptions.isAvailable || subscriptions.isPurchasing)
                } footer: {
                    Text("""
                        Subscriptions renew automatically unless canceled at least 24 hours before the end of the current period, \
                        and renewals are charged to your Apple ID. \
                        You can cancel from your App Store subscriptions. \
                        The free trial does not require payment and does not renew. \
                        With a subscription, the app covers the cost of AI calls.
                        """)
                }

                LegalLinksSection()
            }
            .navigationTitle(feature == nil ? "Max" : "Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                await subscriptions.refresh()
                await subscriptions.loadPlans()
            }
            // Pro → Max のアップグレードでも閉じる（isSubscribed は true のまま変わらないため）。
            .onChange(of: entitlement.paidPlan) { old, new in
                if new != nil, new != old { dismiss() }
            }
            .alert("Error", isPresented: .constant(subscriptions.errorMessage != nil)) {
                Button("OK") { subscriptions.errorMessage = nil }
            } message: {
                Text(subscriptions.errorMessage ?? "")
            }
        }
    }

    private var featureList: some View {
        Section("What You Get with Pro") {
            ForEach(ProFeature.allCases.filter(\.isListed), id: \.self) { item in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        Text(item.summary)
                            .appFont(.caption1)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: item.symbol)
                        .foregroundStyle(item == feature ? Color.accentColor : .secondary)
                }
            }
        }
    }

    /// トライアルの行。App Store を通さないので、課金の設定（RevenueCat）が無くても出せる。
    @ViewBuilder
    private var trialSection: some View {
        if entitlement.isOnTrial, !entitlement.isSubscribed, let ends = entitlement.trialEndsAt {
            Section("Trial") {
                Label("Free trial until \(ends.formatted(date: .abbreviated, time: .shortened))",
                      systemImage: "gift")
            }
        } else if entitlement.canStartTrial {
            Section("Trial") {
                Button {
                    Task { await startTrial() }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("7-Day Free Trial")
                                .appFont(.body, weight: .medium)
                            Text("No payment needed. It ends on its own after 7 days")
                                .appFont(.caption1)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isStartingTrial {
                            ProgressView()
                        } else {
                            Text("Free")
                                .appFont(.body, weight: .semibold)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .disabled(isStartingTrial)
            }
        }
    }

    private func startTrial() async {
        isStartingTrial = true
        defer { isStartingTrial = false }
        do {
            try await entitlement.startTrial()
            dismiss()
        } catch {
            subscriptions.errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var planSection: some View {
        if let reason = subscriptions.unavailableReason {
            Section {
                Label("Billing Is Not Set Up Yet", systemImage: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
            } footer: {
                Text(reason)
            }
        } else if subscriptions.isLoading {
            Section {
                HStack { ProgressView(); Text("Loading plans…") }
            }
        } else if subscriptions.plans.isEmpty {
            Section {
                Label("Couldn't Load Available Plans", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(visibleTiers, id: \.self) { tier in
                Section(tier.title) {
                    ForEach(subscriptions.plans.filter { $0.tier == tier }) { plan in
                        planRow(plan)
                    }
                }
            }
            .disabled(subscriptions.isPurchasing)
        }
    }

    /// Pro の契約者には Max だけを出す（Pro を買い直させない）。
    private var visibleTiers: [PaidPlan] {
        entitlement.paidPlan == .pro ? [.max] : [.pro, .max]
    }

    private func planRow(_ plan: SubscriptionService.Plan) -> some View {
        Button {
            Task {
                if await subscriptions.purchase(plan) { dismiss() }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plan.title)
                            .appFont(.body, weight: .medium)
                        if plan.isRecommended {
                            Text("Recommended")
                                .appFont(.caption2, weight: .semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18), in: .capsule)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(plan.note)
                        .appFont(.caption1)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(plan.price)
                    .appFont(.body, weight: .semibold, monospacedDigits: true)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

/// 「Pro が要る」ことを一覧の中で伝える行。鍵アイコンと解放ボタンだけの小さな部品。
struct LockedFeatureRow: View {

    let feature: ProFeature
    let onUnlock: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(feature.title) is a Pro feature")
                    .appFont(.subheadline)
                Text(feature.summary)
                    .appFont(.caption1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Unlock", action: onUnlock)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}
