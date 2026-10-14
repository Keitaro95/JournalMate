import Foundation

#if DEBUG
/// UI テスト用の起動状態。環境変数 `UI_TEST_STATE` で指定する（DEBUG ビルドにしか入らない）。
///
/// 指定があるときは DB をメモリに置く。端末の実データを汚さず、毎回まっさらな状態から始められる。
/// UserDefaults（オンボーディング完了・同意・トライアル）も消してから、状態に応じて入れ直す。
enum UITestSupport {

    enum State: String {
        /// 初回起動。オンボーディングから。
        case fresh
        /// オンボーディング済み・プランなし（AI 以外は全部使える）。
        case free
        /// オンボーディング済み・トライアル中（全機能）。ゲートウェイを通さずに端末側の写しだけ入れる。
        case trial
    }

    static let state: State? = ProcessInfo.processInfo.environment["UI_TEST_STATE"].flatMap(State.init)

    /// `Entitlement` と `RootView` が UserDefaults を読む前に呼ぶ。
    static func prepareDefaults() {
        guard let state else { return }
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        switch state {
        case .fresh:
            break
        case .free:
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        case .trial:
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            UserDefaults.standard.set(Date().addingTimeInterval(7 * 86_400).timeIntervalSince1970,
                                      forKey: "trialEndsAt")
        }
    }
}
#endif
