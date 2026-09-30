import Foundation
import Testing
@testable import JournalMate

/// 課金まわりの判定。審査で「有料機能にどう辿り着くか」を見られるので、境界を固めておく。
@MainActor
struct BillingTests {

    @Test func proUnlocksEverything() {
        for feature in ProFeature.allCases {
            #expect(Usage.access(to: feature, isPro: true, usedThisMonth: 999) == .pro)
        }
    }

    @Test func freePlanLocksPaidFeatures() {
        for feature in [ProFeature.aiChat, .journalExtract, .journalWrite, .pastRecall, .knowledge] {
            #expect(Usage.access(to: feature, isPro: false, usedThisMonth: 0) == .locked)
        }
    }

    @Test func onboardingHasExactlyOneFreeTry() {
        #expect(Usage.access(to: .onboardingChat, isPro: false, usedThisMonth: 0) == .free(remaining: 1))
        #expect(Usage.access(to: .onboardingChat, isPro: false, usedThisMonth: 1) == .locked)
        #expect(Usage.access(to: .onboardingExtract, isPro: false, usedThisMonth: 0) == .free(remaining: 1))
    }

    @Test func freeQuotaIsCountedPerMonth() throws {
        let store = try Store.inMemory()
        let september = Format.fileTimestamp.date(from: "202609151200")!
        let october = Format.fileTimestamp.date(from: "202610011200")!
        try store.consume(.onboardingChat, on: september)
        #expect(try store.usedThisMonth(.onboardingChat, on: september) == 1)
        #expect(try store.usedThisMonth(.onboardingChat, on: october) == 0)
    }

    @Test func maxHasTwiceTheDailyBudgetOfPro() {
        #expect(TokenBudget.daily(for: .max) == TokenBudget.daily(for: .pro) * 2)
    }

    /// 審査の必須情報：各プランの価格と期間が画面に出ること。
    @Test func everyPlanHasAReferencePriceForBothPeriods() {
        for plan in [PaidPlan.pro, .max] {
            #expect(!plan.referencePrice(isAnnual: false).isEmpty)
            #expect(!plan.referencePrice(isAnnual: true).isEmpty)
            #expect(!plan.title.isEmpty)
        }
    }

    @Test func legalLinksAreHTTPS() {
        for url in [LegalLinks.privacyPolicy, LegalLinks.termsOfUse, LegalLinks.appleEULA, LegalLinks.contact] {
            #expect(url.scheme == "https", "\(url)")
        }
    }

    /// 同意が無いあいだは AI に何も送らない（ガイドライン 5.1.2(i)）。
    @Test func aiConsentDefaultsToOff() {
        let key = "aiDataSharingConsent"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        let entitlement = Entitlement()
        #expect(entitlement.hasAIConsent == false)
        entitlement.setAIConsent(true)
        #expect(Entitlement().hasAIConsent == true)
    }
}
