import SwiftUI

/// ゲームのキャラメイク風の編集画面。上にアバター、下にカテゴリのタブと選択肢。
/// config を書き換えるだけで、上の AvatarView に即座に反映される。
struct AvatarEditorView: View {
    @Binding var config: AvatarConfig
    /// Clef が判定した直後の状態（「AI の結果に戻す」用）
    let detected: AvatarConfig
    /// 質問 id → 選ばれた選択肢の確率
    let confidence: [String: Double]

    @Environment(\.dismiss) private var dismiss
    @State private var category: Category = .hair

    enum Category: String, CaseIterable, Identifiable {
        case face = "輪郭", hair = "髪", hairStyle = "髪型", brows = "眉", eyes = "目"
        case noseMouth = "鼻と口", cheeks = "ほっぺ", facialHair = "ひげ", accessories = "小物", cloth = "服"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AvatarView(config: config)
                    .frame(maxHeight: 260)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color(hex: 0xFFE3C8))

                categoryTabs

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        rows
                    }
                    .padding(16)
                }
            }
            .navigationTitle("スタイリング")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("AIの結果に戻す") { config = detected }
                        .disabled(config == detected)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { dismiss() }.bold()
                }
            }
        }
    }

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Category.allCases) { item in
                    Button {
                        category = item
                    } label: {
                        Text(item.rawValue)
                            .font(.subheadline.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(category == item ? Color(hex: 0xF28020) : Color(.secondarySystemBackground))
                            .foregroundStyle(category == item ? Color.white : Color.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    /// AI の自信が低い項目に「要確認」を付ける
    private func unsure(_ key: String) -> Bool {
        (confidence[key] ?? 1) < 0.6
    }

    @ViewBuilder
    private var rows: some View {
        switch category {
        case .face:
            OptionRow(title: "顔の形", selection: $config.faceShape, needsCheck: unsure("faceShape"))
            OptionRow(title: "肌の色", selection: $config.skinTone, needsCheck: unsure("skinTone"))
        case .hair:
            OptionRow(title: "髪の長さ", selection: $config.hairLength, needsCheck: unsure("hairLength"))
            OptionRow(title: "髪の色", selection: $config.hairColor, needsCheck: unsure("hairColor"))
            OptionRow(title: "髪質", selection: $config.hairTexture, needsCheck: unsure("hairTexture"))
            OptionRow(title: "ボリューム", selection: $config.hairVolume, needsCheck: unsure("hairVolume"))
        case .hairStyle:
            OptionRow(title: "前髪", selection: $config.bangs, needsCheck: unsure("bangs"))
            OptionRow(title: "分け目", selection: $config.parting, needsCheck: unsure("parting"))
            OptionRow(title: "まとめ方", selection: $config.hairTie, needsCheck: unsure("hairTie"))
            FlagRow(title: "髪を立てる", isOn: $config.spiky, needsCheck: unsure("spiky"))
            FlagRow(title: "耳を髪で隠す", isOn: $config.earsHidden, needsCheck: unsure("earsHidden"))
        case .brows:
            OptionRow(title: "眉の太さ", selection: $config.browThickness, needsCheck: unsure("browThickness"))
            OptionRow(title: "眉の形", selection: $config.browShape, needsCheck: unsure("browShape"))
        case .eyes:
            OptionRow(title: "目の大きさ", selection: $config.eyeSize, needsCheck: unsure("eyeSize"))
            OptionRow(title: "目の角度", selection: $config.eyeTilt, needsCheck: unsure("eyeTilt"))
            OptionRow(title: "瞳の色", selection: $config.eyeColor, needsCheck: unsure("eyeColor"))
            FlagRow(title: "一重", isOn: $config.singleLid, needsCheck: unsure("singleLid"))
            FlagRow(title: "長いまつげ", isOn: $config.longLashes, needsCheck: unsure("longLashes"))
        case .noseMouth:
            OptionRow(title: "鼻の大きさ", selection: $config.noseSize, needsCheck: unsure("noseSize"))
            OptionRow(title: "唇の厚さ", selection: $config.lipThickness, needsCheck: unsure("lipThickness"))
            FlagRow(title: "笑顔", isOn: $config.smiling, needsCheck: unsure("smiling"))
            FlagRow(title: "口を開ける", isOn: $config.mouthOpen, needsCheck: unsure("mouthOpen"))
        case .cheeks:
            FlagRow(title: "ほっぺを赤く", isOn: $config.blush, needsCheck: unsure("blush"))
            FlagRow(title: "そばかす", isOn: $config.freckles, needsCheck: unsure("freckles"))
        case .facialHair:
            OptionRow(title: "口ひげ", selection: $config.mustache, needsCheck: unsure("mustache"))
            OptionRow(title: "あごひげ", selection: $config.beard, needsCheck: unsure("beard"))
            FlagRow(title: "長いもみあげ", isOn: $config.longSideburns, needsCheck: unsure("longSideburns"))
        case .accessories:
            OptionRow(title: "メガネ", selection: $config.glasses, needsCheck: unsure("glasses"))
            OptionRow(title: "帽子", selection: $config.hat, needsCheck: unsure("hat"))
            FlagRow(title: "ピアス・イヤリング", isOn: $config.earrings, needsCheck: unsure("earrings"))
        case .cloth:
            OptionRow(title: "服の色", selection: $config.clothColor, needsCheck: unsure("clothColor"))
        }
    }
}

// MARK: - 行

private struct RowTitle: View {
    let title: String
    let needsCheck: Bool
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline.bold())
            if needsCheck {
                Text("要確認")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(hex: 0xF28020).opacity(0.18))
                    .foregroundStyle(Color(hex: 0xC25E00))
                    .clipShape(Capsule())
            }
        }
    }
}

/// 選択式の項目。色の項目は色見本つきのチップになる。
private struct OptionRow<T: AvatarOption>: View {
    let title: String
    @Binding var selection: T
    var needsCheck = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RowTitle(title: title, needsCheck: needsCheck)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(T.allCases), id: \.self) { option in
                        Button {
                            selection = option
                        } label: {
                            chip(option)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 1)
            }
        }
    }

    private func chip(_ option: T) -> some View {
        let selected = option == selection
        return HStack(spacing: 6) {
            if let swatch = option.swatch {
                Circle()
                    .fill(swatch)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 1))
            }
            Text(option.label).font(.subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? Color(hex: 0xFFE3C8) : Color(.secondarySystemBackground))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(selected ? Color(hex: 0xF28020) : .clear, lineWidth: 2))
    }
}

/// はい / いいえの項目
private struct FlagRow: View {
    let title: String
    @Binding var isOn: Bool
    var needsCheck = false

    var body: some View {
        Toggle(isOn: $isOn) {
            RowTitle(title: title, needsCheck: needsCheck)
        }
        .tint(Color(hex: 0xF28020))
    }
}

#Preview {
    AvatarEditorView(
        config: .constant(AvatarConfig()),
        detected: AvatarConfig(),
        confidence: ["parting": 0.34, "mustache": 0.5]
    )
}
