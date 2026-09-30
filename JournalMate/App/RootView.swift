import SwiftUI

struct RootView: View {

    @Environment(Store.self) private var store
    @Environment(Entitlement.self) private var entitlement
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        // タブ名は画面の固有名として、どちらの言語でも英語のまま出す
        // （文中でも「Folders 画面」のように呼んでいる）。String で渡すと翻訳対象から外れる。
        TabView {
            Tab("Chat" as String, systemImage: "bubble.left.and.text.bubble.right") {
                ChatScreen()
            }
            Tab("Journal" as String, systemImage: "square.and.pencil") {
                JournalScreen()
            }
            Tab("Calendar" as String, systemImage: "calendar") {
                CalendarScreen()
            }
            Tab("Folders" as String, systemImage: "folder") {
                TreeScreen()
            }
            Tab("Settings" as String, systemImage: "gearshape") {
                SettingsScreen()
            }
        }
        .fullScreenCover(isPresented: .constant(!hasCompletedOnboarding)) {
            OnboardingScreen(isComplete: $hasCompletedOnboarding)
        }
    }
}
