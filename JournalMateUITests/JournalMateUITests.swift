import XCTest

/// 審査員が辿る導線を、起動から通しで確かめる。
///
/// アプリは `UI_TEST_STATE` を受けて、メモリ DB・まっさらな UserDefaults で起動する（DEBUG のみ。`UITestSupport`）。
/// ネットワーク（ゲートウェイ・App Store）の結果に左右される操作（トライアル開始・購入・AI 応答）は押さず、
/// その手前の画面に必要な情報が出ていることまでを見る。
final class JournalMateUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ state: String) {
        app = XCUIApplication()
        app.launchEnvironment["UI_TEST_STATE"] = state
        // 文言で要素を探すので、端末の言語に関わらず英語で起動する。
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    private func tab(_ name: String) {
        let button = app.tabBars.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "タブ \(name) が無い")
        button.tap()
    }

    private func assertExists(_ element: XCUIElement, _ message: String = "",
                              timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      message.isEmpty ? "\(element) が出ない" : message, file: file, line: line)
    }

    /// 画面のどこかにその文字列を含む要素があるか。
    private func text(containing value: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    /// 種類を問わず、ラベルがちょうど `label` の要素（SwiftUI の Link はボタンにもリンクにもなる）。
    private func element(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// 下へスクロールしながら探す。Form / List は画面外の行をまだ作っていないことがある。
    private func scrollTo(_ label: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(label)
        var swipes = 0
        while !(target.exists && target.isHittable) && swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(target.exists, "\(label) が見つからない", file: file, line: line)
        return target
    }


    // MARK: - 初回起動

    func testOnboardingWalksThroughIntroAndReachesPlanChoice() {
        launch("fresh")

        assertExists(app.staticTexts["JournalMate"], "説明スライドの 1 枚目")
        // 6 枚を Next で送る（最後のボタンは Let's Try Journaling）。
        for _ in 0..<5 {
            app.buttons["Next"].tap()
        }
        assertExists(app.staticTexts["Your Journals Live on This iPhone"],
                     "最後のページで、アプリの削除で記録が消えることを伝える")
        app.buttons["Let's Try Journaling"].tap()

        assertExists(app.staticTexts["Let's try journaling"], "体験の画面")
        app.buttons["Skip"].tap()

        // プラン選択：名称・期間・価格・規約とプライバシーポリシー（ガイドライン 3.1.2）。
        assertExists(app.staticTexts["Choose Your Plan"])
        assertExists(text(containing: "7-Day Free Trial"))
        assertExists(text(containing: "Pro"))
        assertExists(text(containing: "Max"))
        assertExists(text(containing: "/ month"), "月額の価格")
        app.buttons["Annual"].tap()
        assertExists(text(containing: "/ year"), "年額の価格")

        _ = scrollTo("Privacy Policy")
        _ = scrollTo("Terms of Use")
        assertExists(text(containing: "renew automatically"), "自動更新の説明")
    }

    func testSkippingIntroGoesStraightToTryJournaling() {
        launch("fresh")
        assertExists(app.buttons["Skip"])
        app.buttons["Skip"].tap()
        assertExists(app.staticTexts["Let's try journaling"])
    }

    // MARK: - 本編（プランなし）

    func testEveryTabOpensWithoutAPlan() {
        launch("free")

        tab("Chat")
        assertExists(app.buttons["Chat History"])

        tab("Journal")
        assertExists(app.buttons["Save"])

        tab("Calendar")
        assertExists(app.navigationBars["Calendar"])

        tab("Folders")
        assertExists(app.navigationBars["Folders"])
        for name in ["Journal", "Projects", "Areas", "Resources", "Archives"] {
            assertExists(app.cells.staticTexts[name], "ルート \(name)")
        }

        tab("Settings")
        assertExists(app.navigationBars["Settings"])
    }

    func testFreePlanShowsPaywallWhenWriting() {
        launch("free")
        tab("Journal")

        // 入力欄に触れた瞬間に Paywall（なぜ書けないかを見せる）。
        let gate = app.buttons["Writing journals"]
        assertExists(gate, "書く場所に重ねた Paywall への入口")
        gate.tap()

        assertExists(app.navigationBars["Pro"], "Paywall が出る")
        assertExists(text(containing: "This feature needs Pro, Max, or the free trial."))
        _ = scrollTo("Restore Purchases")
        _ = scrollTo("Privacy Policy")
        _ = scrollTo("Terms of Use")

        app.buttons["Close"].tap()
        XCTAssertFalse(app.navigationBars["Pro"].waitForExistence(timeout: 2), "閉じられる")
    }

    func testSettingsShowsPlanDetailsLegalLinksAndBackup() {
        launch("free")
        tab("Settings")

        assertExists(text(containing: "Free"), "今のプラン")
        app.buttons["Change Plan"].tap()
        assertExists(app.staticTexts["Choose Your Plan"])
        assertExists(text(containing: "/ month"))
        app.buttons["Close"].tap()

        assertExists(app.switches.firstMatch, "AI へのデータ送信の同意")
        XCTAssertEqual(app.switches.firstMatch.value as? String, "0", "同意は既定でオフ")

        _ = scrollTo("Export Backup (.zip)")
        _ = scrollTo("Restore from Backup")
        for name in ["Privacy Policy", "Terms of Use", "Terms of Use (EULA)", "Contact Us"] {
            _ = scrollTo(name)
        }
    }

    func testAboutPagesOpenAndClose() {
        launch("free")
        tab("Settings")
        scrollTo("About This App").tap()
        assertExists(app.staticTexts["JournalMate"])
        app.buttons["Close"].firstMatch.tap()

        scrollTo("How the Folder Structure Works").tap()
        assertExists(app.navigationBars["How It Works"])
    }

    func testExportBackupOpensShareSheet() {
        launch("free")
        tab("Settings")
        scrollTo("Export Backup (.zip)").tap()
        // 共有シート（UIActivityViewController）が出れば書き出せている。
        let shareSheet = app.otherElements["ActivityListView"]
        let appeared = shareSheet.waitForExistence(timeout: 15)
            || app.navigationBars["UIActivityContentView"].waitForExistence(timeout: 5)
            || app.buttons["Save to Files"].waitForExistence(timeout: 5)
        XCTAssertTrue(appeared, "共有シートが出ない")
    }

    // MARK: - 本編（トライアル中）

    func testWriteJournalAndFindItInCalendarAndFolders() {
        launch("trial")
        tab("Journal")

        app.buttons["Choose where to save"].tap()
        assertExists(app.navigationBars["Choose Folder"])
        app.cells.staticTexts["Journal"].tap()
        assertExists(app.buttons["Save Here"])
        app.buttons["Save Here"].tap()

        let title = app.textFields["Title"]
        assertExists(title)
        title.tap()
        title.typeText("UI test entry")

        let body = app.textViews.firstMatch
        body.tap()
        body.typeText("Wrote this from the UI test.")

        app.buttons["Save"].tap()
        assertExists(app.alerts["Saved"], "保存できた")
        app.alerts["Saved"].buttons["OK"].tap()

        // Calendar：今日を開いた状態でジャーナルが並ぶ。
        tab("Calendar")
        assertExists(text(containing: "UI test entry"), "カレンダーの今日に出る")

        // Folders：全文検索で見つかる。
        tab("Folders")
        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        assertExists(search)
        search.tap()
        search.typeText("UI test")
        assertExists(text(containing: "UI test entry"), "検索で見つかる")
    }

    func testTrialShowsInSettings() {
        launch("trial")
        tab("Settings")
        assertExists(text(containing: "Trial"))
        assertExists(text(containing: "Free trial: every feature is available"))
    }

    // MARK: - 起動の速さ

    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchEnvironment["UI_TEST_STATE"] = "free"
            app.launch()
        }
    }
}
