import Foundation
import Observation
import Security

/// 無料 / Pro の判定と、AI の呼び先の解決。
///
/// Pro になる経路は 2 つある。ユーザーに API キーを入れさせる経路は持たない。
/// 1. **サブスクリプション**（RevenueCat の `pro` / `max` エンタイトルメント）。原価はこちらが持つので
///    呼び先は自前のゲートウェイになる。状態の正は RevenueCat 側で、ここは写しを持つだけ。
///    Pro と Max の違いはモデルと使える量だけ（`PaidPlan`）。
/// 2. **無料トライアル**（7 日間・Haiku）。App Store を通さない独立したプランで、1 端末 1 回。
///    終われば無料に戻る。開始時刻の正はゲートウェイにあり、ここは終了時刻の写しを持つ。
///
/// 機能ごとの解放判定は `ProFeature` / `Usage` に分けてある。ここは「誰か」だけを見て、
/// 「何が使えるか」は見ない。
@MainActor
@Observable
final class Entitlement {

    /// RevenueCat から流れてくる購読中のプラン。`SubscriptionService` だけが更新する。
    private(set) var paidPlan: PaidPlan?
    var isSubscribed: Bool { paidPlan != nil }
    /// 端末 ID。契約・使用量・無料枠・トライアルは全部これで数える（`DeviceIdentity`）。
    /// RevenueCat の appUserID にも同じ値を使う。
    var appUserID: String { DeviceIdentity.id }

    /// ゲートウェイのセッショントークンを取ってくる処理。
    /// App Attest を扱う `GatewaySession`（Billing/）が起動時に差し込む。
    /// ここに DeviceCheck を持ち込まないのは、この層を iOS 非依存に保つため。
    /// `rejected` にゲートウェイが 401 で断ったトークンを渡すと、それを捨てて取り直す。
    var authorize: (@Sendable (_ rejected: String?) async throws -> String)?
    /// DeviceCheck の端末トークンを取ってくる処理。同じく `GatewaySession` が差し込む。
    /// 無料枠を端末に縛る（入れ直しで戻らないようにする）ためだけに使う。
    var deviceToken: (@Sendable () async -> String?)?

    /// 全機能が開いているか。契約かトライアル中のどちらか。
    var isPro: Bool { isSubscribed || isOnTrial }

    /// AI の機能のために、書いた内容を Anthropic（と中継サーバ）へ送ることに同意しているか。
    /// App Review 5.1.2(i) は、個人データを第三者の AI に渡す前に明示的な同意を求める。
    /// **同意が無いあいだは `client` が nil を返す**ので、どの画面からも送信は起きない。
    private(set) var hasAIConsent: Bool

    init() {
        // 以前のバージョンで入れた API キーが Keychain に残っていれば消す。もう使わない。
        Keychain.delete(Keychain.legacyAPIKeyAccount)
        hasAIConsent = UserDefaults.standard.bool(forKey: Self.aiConsentKey)
        let ends = UserDefaults.standard.double(forKey: Self.trialEndsKey)
        trialEndsAt = ends > 0 ? Date(timeIntervalSince1970: ends) : nil
        isTrialUnavailable = UserDefaults.standard.bool(forKey: Self.trialUnavailableKey)
    }

    // MARK: - 無料トライアル

    /// トライアルの終了時刻。始めていなければ nil。
    private(set) var trialEndsAt: Date?
    /// サーバに「この端末では使えない」と言われた（使用済み・終了済み）。Paywall に出さない。
    private(set) var isTrialUnavailable: Bool

    private static let trialEndsKey = "trialEndsAt"
    private static let trialUnavailableKey = "trialUnavailable"

    var isOnTrial: Bool { trialEndsAt.map { $0 > Date() } ?? false }

    /// Paywall にトライアルを並べてよいか。一度でも始めたら出さない。
    var canStartTrial: Bool {
        trialEndsAt == nil && !isTrialUnavailable && !isSubscribed && BillingConfig.trialStartURL != nil
    }

    /// トライアルの枠で AI を呼ぶか。契約があればそちらを優先する。
    var usesTrial: Bool { isOnTrial && !isSubscribed }

    enum TrialFailure: Swift.Error, LocalizedError {
        case notConfigured
        case ended
        case deviceUsed
        case server(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return String(localized: "The free trial is not available yet.")
            case .ended:
                return String(localized: "Your free trial has ended.")
            case .deviceUsed:
                return String(localized: "The free trial has already been used on this device.")
            case .server(let status):
                return String(localized: "Could not start the free trial (\(status)).")
            }
        }
    }

    /// トライアルを始める。すでに始めていれば、サーバが同じ終了時刻を返す。
    func startTrial() async throws {
        guard let url = BillingConfig.trialStartURL, let authorize else {
            throw TrialFailure.notConfigured
        }
        let device = await deviceToken?()
        func post(rejecting rejected: String?) async throws -> (data: Data, status: Int, token: String) {
            let token = try await authorize(rejected)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let device {
                request.setValue(device, forHTTPHeaderField: "x-device-token")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0, token)
        }

        let first = try await post(rejecting: nil)
        // 手元のトークンが古い（サーバのシークレットを入れ替えた）ときは、取り直して 1 回だけやり直す。
        let (data, status, _) = first.status == 401 ? try await post(rejecting: first.token) : first
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        switch status {
        case 200:
            guard let endsAt = payload?["endsAt"] as? Double else { throw TrialFailure.server(status) }
            setTrialEnds(Date(timeIntervalSince1970: endsAt / 1_000))
        case 409:
            isTrialUnavailable = true
            UserDefaults.standard.set(true, forKey: Self.trialUnavailableKey)
            let scope = (payload?["error"] as? [String: Any])?["scope"] as? String
            throw scope == "ended" ? TrialFailure.ended : TrialFailure.deviceUsed
        default:
            throw TrialFailure.server(status)
        }
    }

    private func setTrialEnds(_ date: Date) {
        trialEndsAt = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.trialEndsKey)
    }

    // MARK: - AI への送信の同意

    private static let aiConsentKey = "aiDataSharingConsent"

    func setAIConsent(_ granted: Bool) {
        hasAIConsent = granted
        UserDefaults.standard.set(granted, forKey: Self.aiConsentKey)
    }

    // MARK: - 購読

    /// `SubscriptionService` からの反映。ここで UI が更新される。
    func updateSubscription(plan: PaidPlan?) {
        paidPlan = plan
    }

    // MARK: - 解放判定

    /// この機能をいま使えるか。無料枠の消費数は `store` から引く。
    /// Pro 専用の機能は DB を引かずに判定する（画面の描画ごとに呼ばれるため）。
    func access(to feature: ProFeature, in store: Store) -> FeatureAccess {
        if isPro { return .pro }
        guard feature.monthlyFreeLimit > 0 else { return .locked }
        let used = (try? store.usedThisMonth(feature)) ?? feature.monthlyFreeLimit
        return Usage.access(to: feature, isPro: false, usedThisMonth: used)
    }

    func canUse(_ feature: ProFeature, in store: Store) -> Bool {
        access(to: feature, in: store).isAllowed
    }

    // MARK: - トークンの上限

    /// 1 日の上限が効くか。**契約者とトライアル中の人**が対象。
    var isMetered: Bool { isSubscribed || usesTrial }

    /// 1 日の上限。プランで変わる。
    var dailyLimit: Int {
        if let paidPlan { return TokenBudget.daily(for: paidPlan) }
        return usesTrial ? TokenBudget.trialDaily : TokenBudget.daily
    }

    /// 上限に当たっていれば、その状況を返す。呼べるなら nil。
    /// AI を呼ぶ手前で必ず通す（走り出したストリームは途中で止められないため）。
    func exhaustedBudget(in store: Store) -> DailyBudget? {
        guard isMetered else { return nil }
        guard let budget = try? store.dailyBudget(limit: dailyLimit) else { return nil }
        return budget.canStart ? nil : budget
    }

    // MARK: - 呼び先

    /// AI の呼び先。どの経路でも自前のゲートウェイを通す。
    ///
    /// `meter` を渡すと、使ったトークンがそこに積まれる。上限の判断に使うので、常に渡してよい。
    ///
    /// 呼び先の優先順は 3 段。
    ///   1. 契約者          → ゲートウェイ（原価はこちら持ち）
    ///   2. トライアル中    → ゲートウェイ（Haiku。サーバが期間と上限を見る）
    ///   3. 無料枠のある機能 → ゲートウェイ（サーバが回数と端末を見る）
    func client(meter: Store? = nil, for feature: ProFeature? = nil) -> ClaudeClient? {
        guard hasAIConsent else { return nil }
        var client: ClaudeClient

        if let paidPlan, let gateway = BillingConfig.messagesURL, let authorize {
            client = ClaudeClient(gateway: gateway, feature: feature, authorize: authorize)
            client.model = ClaudeClient.model(for: paidPlan)
            client.claimedPlan = paidPlan
        } else if usesTrial, let gateway = BillingConfig.messagesURL, let authorize {
            client = ClaudeClient(gateway: gateway, feature: feature, authorize: authorize)
            client.model = ClaudeClient.trialModel
        } else if let feature, feature.monthlyFreeLimit > 0,
                  let gateway = BillingConfig.messagesURL, let authorize {
            client = ClaudeClient(gateway: gateway, feature: feature,
                                  authorize: authorize, deviceToken: deviceToken)
            // 無料枠は Haiku。ゲートウェイも上書きするが、アプリ側の指定も揃えておく。
            client.model = ClaudeClient.trialModel
        } else {
            return nil
        }

        if let meter {
            client.onUsage = { usage in
                Task { @MainActor in try? meter.record(usage) }
            }
            client.onFreeQuota = { feature, used in
                Task { @MainActor in try? meter.syncUsage(feature, used: used) }
            }
        }
        return client
    }
}

/// 端末 ID。**契約・使用量・無料枠・トライアルの主キー**で、RevenueCat の appUserID にも使う。
///
/// iOS には「入れ直しても変わらない端末 ID」を OS がくれる仕組みが無い（プライバシーのため）。
/// そこで初回に UUID を作り、Keychain の **この端末限定**（`ThisDeviceOnly`）の領域に置く。
///   - アプリを削除しても残る → 入れ直しで使用量や無料枠が白紙に戻らない
///   - iCloud キーチェーンやバックアップで**他の端末には移らない** → 端末ごとに別の ID になる
///   - 端末を初期化すると消える（そのときは DeviceCheck のビットが入れ直し対策を引き継ぐ）
///
/// 広告 ID（IDFA）ではなく、このアプリの中だけで使う乱数なので、トラッキングには当たらない。
enum DeviceIdentity {

    static let id: String = {
        if let saved = Keychain.read(account) { return saved }
        let created = UUID().uuidString.lowercased()
        Keychain.write(created, account: account, thisDeviceOnly: true)
        return created
    }()

    private static let account = "device.id"
}

/// 端末 ID などの秘匿値は UserDefaults ではなく Keychain に置く。
enum Keychain {

    /// 以前ユーザーの API キーを置いていた場所。起動時に消すためだけに残す。
    static let legacyAPIKeyAccount = "anthropic.api.key"
    private static let service = "app.journalmate"

    /// `thisDeviceOnly` なら、バックアップから別の端末に復元されても持ち越さない。
    static func write(_ value: String, account: String, thisDeviceOnly: Bool = false) {
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: thisDeviceOnly
                ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                : kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    #if DEBUG
    /// 開発用。Scheme の環境変数 `RESET_KEYCHAIN=1` で起動したとき、このアプリの Keychain を全部消す
    /// （端末 ID・App Attest の keyId）。アプリの削除では Keychain が消えないので、
    /// 「まっさらな端末」として無料枠・トライアル・App Attest を試し直すときに使う。
    /// DEBUG ビルドにしか入らない。
    static func resetIfRequested() {
        guard ProcessInfo.processInfo.environment["RESET_KEYCHAIN"] == "1" else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        print("Keychain: RESET_KEYCHAIN=1 で全部消しました（status \(status)）")
    }
    #endif

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
