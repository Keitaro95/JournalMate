import Foundation

/// 課金まわりの設定値。ここだけ書き換えれば本番に繋がる。
///
/// **鍵の置き場所について。**
/// RevenueCat の公開 SDK キー（`appl_...`）はアプリに入れてよい。公開前提の値で、
/// これ単体では購入も払い戻しもできない。一方 **Anthropic の API キーは絶対に入れない**。
/// バイナリから抜けるし、抜かれたら請求はこちらに来る。だから契約者の AI 呼び出しは
/// `gatewayURL` の中継サーバを通す（サーバ側で appUserID の購読を RevenueCat の API で
/// 検証してから Anthropic に投げる）。
/// 中継サーバを立てるまでは `gatewayURL` を空のままにしておけば、
/// AI は使えない（ユーザーに API キーを入れさせる経路は持たない）。
enum BillingConfig {

    /// RevenueCat の公開 SDK キー。空なら課金機能は「未設定」表示になる。
    static let revenueCatAPIKey = "appl_gyaFuVmLOvyDOFJFubdVyGQhQEU"

    /// RevenueCat 側で作るエンタイトルメント識別子。
    /// Pro の商品は `pro` だけ、Max の商品は `pro` と `max` の**両方**に紐づける。
    static let entitlementID = "pro"
    static let maxEntitlementID = "max"

    /// Max の商品 ID に含まれる文字列。Paywall で Pro と Max を分けて並べるのに使う。
    /// 商品 ID は `app.journalmate.pro.monthly` / `app.journalmate.max.annual` の形にする。
    static let maxProductMarker = ".max."

    /// 中継サーバ（`Gateway/`）のベース URL。空ならゲートウェイ無し。
    /// 例: "https://journalmate-gateway.example.workers.dev"
    private static let gateway = "https://journal-mate-api.ai-swift.com"

    static var gatewayURL: URL? {
        gateway.isEmpty ? nil : URL(string: gateway)
    }

    /// Anthropic への中継口。`ClaudeClient` はここに投げる。
    static var messagesURL: URL? { gatewayURL?.appendingPathComponent("v1/messages") }
    /// App Attest のチャレンジとセッション（`GatewaySession` が使う）。
    static var challengeURL: URL? { gatewayURL?.appendingPathComponent("v1/challenge") }
    static var sessionURL: URL? { gatewayURL?.appendingPathComponent("v1/session") }
    /// アプリ内の無料トライアルを始める（`Entitlement.startTrial`）。
    static var trialStartURL: URL? { gatewayURL?.appendingPathComponent("v1/trial/start") }

    /// 課金の導線を出してよいか（キー未設定のまま Paywall を出しても買えない）。
    static var isConfigured: Bool { !revenueCatAPIKey.isEmpty }
}
