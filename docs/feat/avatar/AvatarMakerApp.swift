import SwiftUI

// 撮影 → 判定 → アバター表示 → 編集 の流れをつなぐ画面。iOS 17 以降。

@main
struct AvatarMakerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    /// いま表示・編集しているアバター（nil なら未作成）
    @State private var config: AvatarConfig? = AvatarStorage.load()
    /// Clef が判定した直後の状態と、各項目の確率
    @State private var detected = AvatarConfig()
    @State private var confidence: [String: Double] = [:]

    @State private var isAnalyzing = false
    @State private var showCamera = false
    @State private var showEditor = false
    @State private var errorMessage: String?

    private let accent = Color(hex: 0xF28020)

    var body: some View {
        VStack(spacing: 24) {
            Text("アバターメーカー").font(.largeTitle.bold())

            ZStack {
                RoundedRectangle(cornerRadius: 28).fill(Color(hex: 0xFFE3C8))
                if isAnalyzing {
                    ProgressView("顔の特徴を判定中…")
                } else if let config {
                    AvatarView(config: config).padding(24)
                } else {
                    VStack(spacing: 8) {
                        Text("顔を正面から撮影します").font(.headline)
                        Text("明るい場所で、顔が枠いっぱいに入るように撮ってね")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
            .aspectRatio(1, contentMode: .fit)

            if config != nil, !isAnalyzing {
                Button("スタイリングを編集") { showEditor = true }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.large)
                HStack(spacing: 24) {
                    Button("撮り直す") { showCamera = true }
                    if let image = renderedImage() {
                        ShareLink(item: image, preview: SharePreview("アバター", image: image)) {
                            Text("画像を共有")
                        }
                    }
                }
            } else {
                Button("カメラを起動") { showCamera = true }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.large)
                    .disabled(isAnalyzing)
            }

            Text("撮影した写真は判定のためだけに送信され、保存されません。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                Task { await analyze(image) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showEditor) {
            if let binding = Binding($config) {
                AvatarEditorView(config: binding, detected: detected, confidence: confidence)
            }
        }
        .onChange(of: config) { _, newValue in
            AvatarStorage.save(newValue)
        }
        .alert("エラー", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func analyze(_ image: UIImage) async {
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let result = try await ClefClient.analyze(image)
            let newConfig = AvatarConfig(answers: result.answers)
            detected = newConfig
            confidence = result.answers.mapValues(\.confidence)
            config = newConfig
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 共有用にアバターを画像化する
    @MainActor
    private func renderedImage() -> Image? {
        guard let config else { return nil }
        let renderer = ImageRenderer(
            content: AvatarView(config: config)
                .frame(width: 400, height: 440)
                .background(Color(hex: 0xFFE3C8))
        )
        renderer.scale = 3
        return renderer.uiImage.map(Image.init(uiImage:))
    }
}

/// アバターの設定を JSON で端末に保存する（写真そのものは保存しない）
enum AvatarStorage {
    private static let key = "avatarConfig"

    static func load() -> AvatarConfig? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AvatarConfig.self, from: data)
    }

    static func save(_ config: AvatarConfig?) {
        guard let config, let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
