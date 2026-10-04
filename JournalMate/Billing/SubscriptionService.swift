import Foundation
import Observation

#if canImport(RevenueCat)
import RevenueCat
#endif

/// RevenueCat の薄いラッパ。購読状態は `Entitlement` に流し込むだけで、
/// 画面はこれまで通り `Entitlement` と `ProFeature` しか見ない。
///
/// SDK（RevenueCat 5.x）を Swift Package で足すまでは `#if canImport` で丸ごと無効になり、
/// 課金は「未設定」として動く。足した時点でこのファイルが生きる。
///
/// パッケージの追加手順:
///   Xcode > File > Add Package Dependencies…
///   https://github.com/RevenueCat/purchases-ios  （Up to Next Major 5.0.0）
///   プロダクト `RevenueCat` を JournalMate ターゲットに追加
@MainActor
@Observable
final class SubscriptionService {

    /// Paywall に並べる 1 プラン。RevenueCat の型を画面まで持ち込まないための写し。
    struct Plan: Identifiable, Hashable {
        /// RevenueCat の package identifier。購入時に引き当てる鍵。
        var id: String
        var title: String
        /// ローカライズ済みの価格文字列（"¥800" など）。自前で組み立てない。
        var price: String
        var note: String
        /// 年額など、月額換算が効くものを目立たせるため。
        var isRecommended: Bool
        /// 年額か。プラン選択の「月額 / 年額」の切り替えで引き当てる。
        var isAnnual: Bool
        /// Pro か Max か。Paywall で分けて並べる。
        var tier: PaidPlan
    }

    private(set) var plans: [Plan] = []
    private(set) var isLoading = false
    /// 購入・復元の実行中。ボタンの二度押しを塞ぐ。
    private(set) var isPurchasing = false
    var errorMessage: String?

    /// SDK が組み込まれていて、公開キーも設定済みか。
    var isAvailable: Bool {
        #if canImport(RevenueCat)
        return BillingConfig.isConfigured
        #else
        return false
        #endif
    }

    /// 課金が使えない理由。設定画面と Paywall でそのまま出す。
    var unavailableReason: String? {
        #if canImport(RevenueCat)
        return BillingConfig.isConfigured ? nil
            : String(localized: "The RevenueCat public key is not set (BillingConfig.revenueCatAPIKey).")
        #else
        return String(localized: "The RevenueCat SDK is not integrated yet. Add the purchases-ios package in Xcode to enable billing.")
        #endif
    }

    private let entitlement: Entitlement
    private var observation: Task<Void, Never>?

    #if canImport(RevenueCat)
    /// package identifier → RevenueCat の Package。
    private var packages: [String: Package] = [:]
    #endif

    init(entitlement: Entitlement) {
        self.entitlement = entitlement
    }

    // MARK: - 起動

    /// アプリ起動時に 1 度だけ。設定 → 現在の購読状態 → 以後の変化の監視。
    func start() {
        guard isAvailable, observation == nil else { return }

        #if canImport(RevenueCat)
        // appUserID は端末 ID に固定する（匿名 ID に任せると、入れ直すたびに別人になり、
        // ゲートウェイの使用量の台帳も白紙に戻ってしまう）。
        Purchases.configure(withAPIKey: BillingConfig.revenueCatAPIKey, appUserID: DeviceIdentity.id)

        // 変化は customerInfoStream から受ける（更新・失効・別端末での購入も届く）。
        observation = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                self?.apply(info)
            }
        }

        Task { await refresh() }
        #endif
    }

    /// 現在の購読状態を取り直す。復帰時や Paywall を開いたときに呼ぶ。
    func refresh() async {
        #if canImport(RevenueCat)
        guard isAvailable else { return }
        do {
            apply(try await Purchases.shared.customerInfo())
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
    }

    // MARK: - 商品

    /// Offering を読み込んで Paywall に並べる。
    func loadPlans() async {
        #if canImport(RevenueCat)
        guard isAvailable, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            guard let offering = try await Purchases.shared.offerings().current else {
                plans = []
                return
            }
            packages = Dictionary(
                offering.availablePackages.map { ($0.identifier, $0) },
                uniquingKeysWith: { first, _ in first })

            plans = offering.availablePackages.map { package in
                let product = package.storeProduct
                // Max の package は custom になるので packageType ではなく期間で見る。
                let isAnnual = product.subscriptionPeriod?.unit == .year
                let tier: PaidPlan = product.productIdentifier.contains(BillingConfig.maxProductMarker)
                    ? .max : .pro
                return Plan(
                    id: package.identifier,
                    title: Self.title(tier: tier, isAnnual: isAnnual),
                    price: product.localizedPriceString,
                    note: Self.note(for: package, isAnnual: isAnnual),
                    isRecommended: isAnnual,
                    isAnnual: isAnnual,
                    tier: tier)
            }
            .sorted { ($0.tier == .max ? 1 : 0, $0.isRecommended ? 0 : 1)
                    < ($1.tier == .max ? 1 : 0, $1.isRecommended ? 0 : 1) }
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
    }

    // MARK: - 購入

    /// 購入する。成功したら true。ユーザーが自分で閉じたときは false（エラーにはしない）。
    @discardableResult
    func purchase(_ plan: Plan) async -> Bool {
        #if canImport(RevenueCat)
        guard isAvailable, let package = packages[plan.id], !isPurchasing else { return false }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await Purchases.shared.purchase(package: package)
            guard !result.userCancelled else { return false }
            apply(result.customerInfo)
            return entitlement.paidPlan == plan.tier
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        #else
        return false
        #endif
    }

    /// 復元。機種変更と再インストールのための必須導線（審査でも見られる）。
    @discardableResult
    func restore() async -> Bool {
        #if canImport(RevenueCat)
        guard isAvailable, !isPurchasing else { return false }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            apply(try await Purchases.shared.restorePurchases())
            if !entitlement.isSubscribed {
                errorMessage = String(localized: "No purchases to restore were found.")
            }
            return entitlement.isSubscribed
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        #else
        return false
        #endif
    }

    // MARK: - 反映

    #if canImport(RevenueCat)
    /// `max` を先に見る。Max の商品は `pro` にも紐づいているので、`pro` だけ見ると Max が Pro になる。
    private func apply(_ info: CustomerInfo) {
        let isActive = { (id: String) in info.entitlements[id]?.isActive == true }
        let plan: PaidPlan? = isActive(BillingConfig.maxEntitlementID) ? .max
            : isActive(BillingConfig.entitlementID) ? .pro
            : nil
        let active = plan.flatMap { info.entitlements[$0 == .max ? BillingConfig.maxEntitlementID : BillingConfig.entitlementID] }
        entitlement.updateSubscription(plan: plan,
                                       renewsAt: active?.expirationDate,
                                       willRenew: active?.willRenew ?? true)
    }

    private static func title(tier: PaidPlan, isAnnual: Bool) -> String {
        switch (tier, isAnnual) {
        case (.pro, false): return String(localized: "Pro Monthly")
        case (.pro, true): return String(localized: "Pro Annual")
        case (.max, false): return String(localized: "Max Monthly")
        case (.max, true): return String(localized: "Max Annual")
        }
    }

    /// 無料トライアルや導入価格があるときは、それを添えて出す。
    private static func note(for package: Package, isAnnual: Bool) -> String {
        let product = package.storeProduct
        if let intro = product.introductoryDiscount, intro.paymentMode == .freeTrial {
            return String(localized: "Free for \(Self.periodText(intro.subscriptionPeriod))")
        }
        return isAnnual
            ? String(localized: "Better value than monthly")
            : String(localized: "Cancel anytime")
    }

    /// 「1 週間」「1 week」のような期間の表記。単位の訳と複数形は OS に任せる。
    private static func periodText(_ period: SubscriptionPeriod) -> String {
        var components = DateComponents()
        switch period.unit {
        case .day: components.day = period.value
        case .week: components.weekOfMonth = period.value
        case .month: components.month = period.value
        case .year: components.year = period.value
        @unknown default: components.day = period.value
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        return formatter.string(from: components) ?? "\(period.value)"
    }
    #endif
}
