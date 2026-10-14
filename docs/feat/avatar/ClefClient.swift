import UIKit

/// Worker を呼んで判定結果を受け取る。Cloudflare の API トークンはアプリに入れない。
enum ClefClient {
    // TODO: `wrangler deploy` で表示された URL に置き換える
    static let endpoint = URL(string: "https://avatar-clef.YOUR-SUBDOMAIN.workers.dev")!
    // Worker に APP_TOKEN を設定した場合だけ同じ値を入れる
    static let appToken: String? = nil

    struct Result: Decodable {
        let answers: [String: ClefAnswer]
        let ms: Int?
    }

    enum Failure: LocalizedError {
        case encode
        case server(Int, String)
        var errorDescription: String? {
            switch self {
            case .encode: "写真を変換できませんでした"
            case .server(let code, let body): "判定に失敗しました (\(code)) \(body)"
            }
        }
    }

    static func analyze(_ image: UIImage) async throws -> Result {
        guard let dataURL = jpegDataURL(from: image) else { throw Failure.encode }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let appToken { request.setValue(appToken, forHTTPHeaderField: "x-app-token") }
        request.httpBody = try JSONEncoder().encode(["image": dataURL])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.server(status, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(Result.self, from: data)
    }

    /// 長辺 1024px の JPEG に縮めて data URL にする（Clef の上限は 1 枚 4MiB）。
    /// 描き直すことで、カメラ画像の向き（EXIF）も正しい向きに焼き込まれる。
    static func jpegDataURL(from image: UIImage, maxSide: CGFloat = 1024) -> String? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let ratio = min(1, maxSide / longest)
        let target = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = resized.jpegData(compressionQuality: 0.8) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }
}
