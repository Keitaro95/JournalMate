import SwiftUI

@main
struct JournalMateApp: App {

    /// DB を開けなかったときだけ nil。画面はその事実を隠さず出す。
    @State private var store: Store?
    @State private var startupError: String?
    @State private var entitlement: Entitlement
    @State private var subscriptions: SubscriptionService
    @State private var gateway: GatewaySession

    init() {
        #if DEBUG
        // 端末 ID を読む前に消す（`DeviceIdentity.id` は最初に読んだ値を持ち続ける）。
        Keychain.resetIfRequested()
        UITestSupport.prepareDefaults()
        #endif
        AppFont.applyToSystemBars()

        // 購読状態の正は RevenueCat 側にある。Entitlement はその写しを持つだけなので、
        // 先に作っておいて SubscriptionService から流し込む。
        let entitlement = Entitlement()
        _entitlement = State(initialValue: entitlement)
        _subscriptions = State(initialValue: SubscriptionService(entitlement: entitlement))
        _gateway = State(initialValue: GatewaySession(entitlement: entitlement))

        do {
            #if DEBUG
            // UI テストでは端末の DB に触れない。
            let store = try UITestSupport.state == nil ? Store() : Store.inMemory()
            #else
            let store = try Store()
            #endif
            try store.purge()
            _store = State(initialValue: store)
        } catch {
            _startupError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let store {
                RootView()
                    .appFont()
                    .dismissesKeyboardOnTapOutside()
                    .environment(store)
                    .environment(entitlement)
                    .environment(subscriptions)
                    .task {
                        gateway.install()
                        subscriptions.start()
                    }
            } else {
                StartupErrorView(message: startupError ?? String(localized: "Unknown error"))
                    .appFont()
            }
        }
    }
}

private struct StartupErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Could Not Open the Database", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
    }
}
