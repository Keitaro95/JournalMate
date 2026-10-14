import CryptoKit
import DeviceCheck
import Foundation
import Observation
import os

/// ゲートウェイのセッション。App Attest で「本物のアプリである」ことを示し、
/// 24 時間ぶんのトークンを受け取る。
///
/// 流れ（サーバ側 `Gateway/src/session.ts` と対になる）:
///   1. POST /v1/challenge            → 使い捨てのチャレンジ
///   2. 初回は attestKey、以後は generateAssertion で署名
///   3. POST /v1/session              → トークン
///
/// **署名する平文は "チャレンジ.appUserID"。** 両側で同じ組み立て方にすること
/// （チャレンジだけだと、署名を別のアカウントに使い回せてしまう）。
@MainActor
@Observable
final class GatewaySession {

    private let entitlement: Entitlement
    private var token: String?
    private var expiresAt: Date?
    /// 同時に何本も呼ばれても、取得は 1 回で済ませる。
    private var inFlight: Task<String, Error>?

    init(entitlement: Entitlement) {
        self.entitlement = entitlement
    }

    /// `Entitlement` に「トークンの取り方」と「端末トークンの取り方」を差し込む。
    /// 起動時に 1 度だけ。
    func install() {
        entitlement.authorize = { [weak self] rejected in
            guard let self else { throw Failure.unavailable }
            return try await self.currentToken(rejecting: rejected)
        }
        entitlement.deviceToken = { await Self.deviceToken() }
    }

    /// DeviceCheck の端末トークン。無料枠を端末に縛るためにサーバへ渡す。
    ///
    /// `identifierForVendor` では駄目で、これでなければならない理由:
    /// あれはアプリを消すと作り直されるが、DeviceCheck のビットは Apple 側に残る。
    /// 「入れ直せば無料枠が戻る」を塞げるのはこちらだけ。
    /// 取れなくても呼び出しは止めない（サーバ側は共有プールの天井で守られている）。
    static func deviceToken() async -> String? {
        let device = DCDevice.current
        guard device.isSupported else { return nil }
        return try? await device.generateToken().base64EncodedString()
    }

    enum Failure: Swift.Error, LocalizedError {
        case unavailable
        case notConfigured
        case notSupported
        /// DCError のコード（0 不明 / 1 非対応 / 2 入力不正 / 3 鍵が無効 / 4 Apple のサーバが応答しない）
        case appAttest(Int)
        case server(Int, String)

        /// 端末の確認そのものを断られた（401 / 400）。手元の鍵を捨てて attestation からやり直せば通る見込みがある。
        var isAttestRejected: Bool {
            if case .server(let status, _) = self { return status == 401 || status == 400 }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return String(localized: "We couldn't connect to AI right now. Please wait a moment and try again.")
            case .notConfigured:
                return String(localized: "The relay server is not configured (BillingConfig.gateway)")
            case .notSupported:
                return String(localized: "App Attest is not available on this device")
            case .appAttest:
                return String(localized: "We couldn't connect to AI right now. Please wait a moment and try again.")
            case .server:
                // サーバの本文（JSON）は見せない。中身は `post` でログにだけ残す。
                return String(localized: "We couldn't connect to AI right now. Please wait a moment and try again.")
            }
        }
    }

    // MARK: - トークン

    /// 期限内のトークンがあればそれを、無ければ取り直す。
    ///
    /// `rejected` はゲートウェイが 401 で断ったトークン。サーバの `SESSION_SECRET` を入れ替えると
    /// 期限内でも通らなくなるので、捨てて取り直す。捨てるのは手元のものと同じときだけ
    /// （同時に何本も 401 になっても、取り直しは 1 回で済む）。
    func currentToken(rejecting rejected: String? = nil) async throws -> String {
        if let rejected, rejected == token {
            token = nil
            expiresAt = nil
        }
        // 期限ぎりぎりのものは使わない（通信の最中に切れると 401 になる）。
        if let token, let expiresAt, expiresAt.timeIntervalSinceNow > 60 {
            return token
        }
        if let inFlight { return try await inFlight.value }

        let task = Task { try await authenticate() }
        inFlight = task
        defer { inFlight = nil }

        let token = try await task.value
        return token
    }

    /// `retried` は、サーバに断られて鍵を作り直した後の 2 回目か。やり直しは 1 回だけ（ループさせない）。
    private func authenticate(retried: Bool = false) async throws -> String {
        guard let challengeURL = BillingConfig.challengeURL,
              let sessionURL = BillingConfig.sessionURL else { throw Failure.notConfigured }
        // 端末 ID。ゲートウェイはこれで契約・使用量・無料枠・トライアルを引く。
        let appUserID = DeviceIdentity.id

        let challenge = try await requestChallenge(from: challengeURL)

        if let bypass = Self.devBypassToken {
            return try await authenticateWithoutAttest(
                challenge: challenge, appUserID: appUserID, bypass: bypass, sessionURL: sessionURL)
        }

        // サーバ側 `clientData(challenge, appUserId)` と同じ組み立て方。
        let clientDataHash = Data(SHA256.hash(data: Data("\(challenge).\(appUserID)".utf8)))

        let service = DCAppAttestService.shared
        guard service.isSupported else {
            #if targetEnvironment(simulator)
            // シミュレータで App Attest に来たら、合言葉が渡っていないということ。
            print("GatewaySession: シミュレータでは Scheme の環境変数 GATEWAY_DEV_BYPASS が必要（cloudflare.md §7）")
            #endif
            throw Failure.notSupported
        }

        var payload: [String: String] = [
            "appUserId": appUserID,
            "challenge": challenge,
        ]

        // 端末の鍵は 1 度作ったら使い回す。作り直すと初回検証からやり直しになる。
        if let keyID = Keychain.read(Self.keyIDAccount) {
            let assertion: Data
            do {
                assertion = try await service.generateAssertion(keyID, clientDataHash: clientDataHash)
            } catch let error as DCError where error.code != .serverUnavailable {
                // 入れ直すと、鍵の本体は消えるのに Keychain の keyId だけが残る。
                // その keyId では署名できないので捨てて、鍵を作るところからやり直す
                // （新しい鍵は、サーバで同じ端末 ID に結びつく）。
                // invalidKey のはずだが、端末によって invalidInput などで返ることがあるので広く拾う。
                Keychain.delete(Self.keyIDAccount)
                return try await authenticate(retried: retried)
            } catch let error as DCError {
                Self.logger.error("App Attest failed: \(error.code.rawValue)")
                throw Failure.appAttest(error.code.rawValue)
            }
            payload["keyId"] = keyID
            payload["assertion"] = assertion.base64EncodedString()
        } else {
            let keyID: String
            let attestation: Data
            do {
                keyID = try await service.generateKey()
                attestation = try await Self.attestWithRetry(service, keyID: keyID, clientDataHash: clientDataHash)
            } catch let error as DCError {
                Self.logger.error("App Attest failed: \(error.code.rawValue)")
                throw Failure.appAttest(error.code.rawValue)
            }
            payload["keyId"] = keyID
            payload["attestation"] = attestation.base64EncodedString()
        }

        let issued: Issued
        do {
            issued = try await postSession(to: sessionURL, payload: payload)
        } catch let failure as Failure where failure.isAttestRejected && !retried {
            // サーバに鍵が登録されていない（初回の登録が途中で落ちた・KV から消えた）か、検証で弾かれた。
            // 手元の keyId を捨てて、鍵を作るところから 1 回だけやり直す
            // （新しい鍵は、サーバで同じ端末 ID に結びつく）。
            Keychain.delete(Self.keyIDAccount)
            return try await authenticate(retried: true)
        }
        // 鍵の保存は、サーバが登録を受け付けてから。先に保存すると、初回の登録が落ちたときに
        // 「手元に鍵があるのにサーバには無い」状態になり、assertion がずっと通らない。
        if payload["attestation"] != nil, let keyID = payload["keyId"] {
            Keychain.write(keyID, account: Self.keyIDAccount)
        }
        token = issued.token
        expiresAt = Date(timeIntervalSince1970: issued.expiresAt)
        return issued.token
    }

    /// Apple の attestation サーバは一時的に serverUnavailable を返すことがある。
    /// Apple の推奨どおり、同じ鍵のまま少し待ってやり直す。
    private static func attestWithRetry(_ service: DCAppAttestService, keyID: String,
                                        clientDataHash: Data) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await service.attestKey(keyID, clientDataHash: clientDataHash)
            } catch let error as DCError where error.code == .serverUnavailable && attempt < 2 {
                attempt += 1
                try await Task.sleep(for: .seconds(attempt))
            }
        }
    }

    // MARK: - シミュレータ（開発専用）

    /// シミュレータには App Attest が無いので、開発中だけ合言葉でセッションを取る。
    /// ゲートウェイ側が `ATTEST_MODE = "off"` で、同じ値を `DEV_BYPASS_TOKEN` に持っているときだけ通る。
    ///
    /// 値は Xcode の Scheme > Run > Arguments > Environment Variables の `GATEWAY_DEV_BYPASS` から読む
    /// （ソースに書かないため）。**DEBUG のシミュレータ実行でしか読まない**ので、
    /// 実機や App Store のビルドにはこの経路そのものが入らない。
    ///
    /// Scheme の環境変数は Xcode から Run したときにしか渡らない。ホーム画面のアイコンから
    /// 開き直すと消えてしまうので、1 度受け取った値はシミュレータの UserDefaults に控えておく。
    private static var devBypassToken: String? {
        #if DEBUG && targetEnvironment(simulator)
        let key = "gateway.dev.bypass"
        if let value = ProcessInfo.processInfo.environment["GATEWAY_DEV_BYPASS"], !value.isEmpty {
            UserDefaults.standard.set(value, forKey: key)
            return value
        }
        let saved = UserDefaults.standard.string(forKey: key)
        return saved?.isEmpty == false ? saved : nil
        #else
        return nil
        #endif
    }

    /// App Attest の代わりに、端末の鍵 ID の代用品（Keychain に保存した UUID）で名乗る。
    /// サーバは keyId で無料枠やトライアルの台帳を引くので、毎回変えずに使い回す。
    private func authenticateWithoutAttest(challenge: String, appUserID: String,
                                           bypass: String, sessionURL: URL) async throws -> String {
        let keyID: String
        if let saved = Keychain.read(Self.devKeyIDAccount) {
            keyID = saved
        } else {
            keyID = "simulator-\(UUID().uuidString)"
            Keychain.write(keyID, account: Self.devKeyIDAccount)
        }

        let data = try await post(sessionURL,
                                  body: ["appUserId": appUserID, "challenge": challenge, "keyId": keyID],
                                  headers: ["x-dev-bypass": bypass])
        let issued = try JSONDecoder().decode(Issued.self, from: data)
        token = issued.token
        expiresAt = Date(timeIntervalSince1970: issued.expiresAt)
        return issued.token
    }

    private static let devKeyIDAccount = "appattest.dev.key.id"

    // MARK: - 通信

    private struct Challenge: Decodable { var challenge: String }
    private struct Issued: Decodable {
        var token: String
        var expiresAt: TimeInterval
    }

    private func requestChallenge(from url: URL) async throws -> String {
        let data = try await post(url, body: [:])
        return try JSONDecoder().decode(Challenge.self, from: data).challenge
    }

    private func postSession(to url: URL, payload: [String: String]) async throws -> Issued {
        let data = try await post(url, body: payload)
        return try JSONDecoder().decode(Issued.self, from: data)
    }

    private func post(_ url: URL, body: [String: String],
                      headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.logger.error("\(url.path, privacy: .public) returned \(status): \(body, privacy: .public)")
            throw Failure.server(status, body)
        }
        return data
    }

    private static let keyIDAccount = "appattest.key.id"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "JournalMate", category: "GatewaySession")
}
