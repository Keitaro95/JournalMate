import SwiftUI

// アバターの全設定。プロパティ名は Worker の質問 id、enum の rawValue は選択肢 id と一致させている。
// Clef の判定結果も、編集画面での変更も、保存データも、すべてこの 1 つの構造体。

protocol AvatarOption: RawRepresentable, CaseIterable, Hashable, Codable where RawValue == String {
    var label: String { get }
    var swatch: Color? { get }
}
extension AvatarOption {
    var swatch: Color? { nil }
}

struct AvatarConfig: Codable, Equatable {
    // 輪郭
    var faceShape: FaceShape = .oval
    var skinTone: SkinTone = .medium
    // 服
    var clothColor: ClothColor = .gray
    // 髪
    var hairLength: HairLength = .short
    var hairColor: HairColor = .black
    var hairTexture: HairTexture = .straight
    var hairVolume: HairVolume = .normal
    // 髪型
    var bangs: Bangs = .down
    var parting: Parting = .none
    var spiky = false
    var hairTie: HairTie = .down
    var earsHidden = false
    // 眉
    var browThickness: Thickness = .normal
    var browShape: BrowShape = .straight
    // 目
    var singleLid = false
    var eyeSize: SizeLevel = .normal
    var eyeTilt: EyeTilt = .normal
    var eyeColor: EyeColor = .darkBrown
    var longLashes = false
    // 鼻と口
    var noseSize: SizeLevel = .normal
    var lipThickness: Thickness = .normal
    var smiling = true
    var mouthOpen = false
    // ほっぺ
    var blush = false
    var freckles = false
    // ひげ
    var mustache: Mustache = .none
    var beard: Beard = .none
    var longSideburns = false
    // 小物
    var glasses: Glasses = .none
    var earrings = false
    var hat: Hat = .none
}

// MARK: - Clef の回答から作る

struct ClefAnswer: Decodable {
    let value: String
    let confidence: Double
}

extension AvatarConfig {
    /// Worker が返した answers から設定を組み立てる。欠けている項目・未知の値は既定値のまま。
    init(answers: [String: ClefAnswer]) {
        self.init()
        func pick<T: AvatarOption>(_ key: String, _ fallback: T) -> T {
            answers[key].flatMap { T(rawValue: $0.value) } ?? fallback
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            answers[key].map { $0.value == "yes" } ?? fallback
        }
        faceShape = pick("faceShape", faceShape)
        skinTone = pick("skinTone", skinTone)
        clothColor = pick("clothColor", clothColor)
        hairLength = pick("hairLength", hairLength)
        hairColor = pick("hairColor", hairColor)
        hairTexture = pick("hairTexture", hairTexture)
        hairVolume = pick("hairVolume", hairVolume)
        bangs = pick("bangs", bangs)
        parting = pick("parting", parting)
        spiky = flag("spiky", spiky)
        hairTie = pick("hairTie", hairTie)
        earsHidden = flag("earsHidden", earsHidden)
        browThickness = pick("browThickness", browThickness)
        browShape = pick("browShape", browShape)
        singleLid = flag("singleLid", singleLid)
        eyeSize = pick("eyeSize", eyeSize)
        eyeTilt = pick("eyeTilt", eyeTilt)
        eyeColor = pick("eyeColor", eyeColor)
        longLashes = flag("longLashes", longLashes)
        noseSize = pick("noseSize", noseSize)
        lipThickness = pick("lipThickness", lipThickness)
        smiling = flag("smiling", smiling)
        mouthOpen = flag("mouthOpen", mouthOpen)
        blush = flag("blush", blush)
        freckles = flag("freckles", freckles)
        mustache = pick("mustache", mustache)
        beard = pick("beard", beard)
        longSideburns = flag("longSideburns", longSideburns)
        glasses = pick("glasses", glasses)
        earrings = flag("earrings", earrings)
        hat = pick("hat", hat)
    }
}

// MARK: - 選択肢

enum FaceShape: String, AvatarOption {
    case round, oval, long, square
    var label: String { ["round": "丸顔", "oval": "たまご型", "long": "面長", "square": "ベース型"][rawValue] ?? rawValue }
}

enum SkinTone: String, AvatarOption {
    case fair, medium, tan, dark
    var label: String { ["fair": "色白", "medium": "ふつう", "tan": "小麦色", "dark": "褐色"][rawValue] ?? rawValue }
    var color: Color {
        switch self {
        case .fair: Color(hex: 0xFFE3CF)
        case .medium: Color(hex: 0xF6C9A4)
        case .tan: Color(hex: 0xD9A06F)
        case .dark: Color(hex: 0x8D5A3B)
        }
    }
    var swatch: Color? { color }
}

enum ClothColor: String, AvatarOption {
    case gray, white, black, navy, blue, red, green, yellow, pink, brown
    var label: String {
        ["gray": "グレー", "white": "白", "black": "黒", "navy": "ネイビー", "blue": "青",
         "red": "赤", "green": "緑", "yellow": "黄", "pink": "ピンク", "brown": "ブラウン"][rawValue] ?? rawValue
    }
    var color: Color {
        switch self {
        case .gray: Color(hex: 0x9AA0A6)
        case .white: Color(hex: 0xF4F4F1)
        case .black: Color(hex: 0x2B2B30)
        case .navy: Color(hex: 0x27335A)
        case .blue: Color(hex: 0x3F7FD9)
        case .red: Color(hex: 0xD9483F)
        case .green: Color(hex: 0x3F9E63)
        case .yellow: Color(hex: 0xF2C43D)
        case .pink: Color(hex: 0xF08FB0)
        case .brown: Color(hex: 0x9B7653)
        }
    }
    var swatch: Color? { color }
}

enum HairLength: String, AvatarOption {
    case none, short, medium, long
    var label: String { ["none": "なし", "short": "ショート", "medium": "ミディアム", "long": "ロング"][rawValue] ?? rawValue }
}

enum HairColor: String, AvatarOption {
    case black, darkBrown, brown, blonde, red, gray, white
    var label: String {
        ["black": "黒", "darkBrown": "こげ茶", "brown": "茶", "blonde": "金", "red": "赤", "gray": "グレー", "white": "白"][rawValue] ?? rawValue
    }
    var color: Color {
        switch self {
        case .black: Color(hex: 0x26222A)
        case .darkBrown: Color(hex: 0x4A3328)
        case .brown: Color(hex: 0x8A5A38)
        case .blonde: Color(hex: 0xE3BC62)
        case .red: Color(hex: 0xB5502F)
        case .gray: Color(hex: 0x9A9A9E)
        case .white: Color(hex: 0xECECEC)
        }
    }
    var swatch: Color? { color }
}

enum HairTexture: String, AvatarOption {
    case straight, wavy, curly
    var label: String { ["straight": "ストレート", "wavy": "ウェーブ", "curly": "カール"][rawValue] ?? rawValue }
}

enum HairVolume: String, AvatarOption {
    case low, normal, high
    var label: String { ["low": "少なめ", "normal": "ふつう", "high": "多め"][rawValue] ?? rawValue }
}

enum Bangs: String, AvatarOption {
    case none, down, side
    var label: String { ["none": "なし", "down": "下ろす", "side": "横に流す"][rawValue] ?? rawValue }
}

enum Parting: String, AvatarOption {
    case none, left, center, right
    var label: String { ["none": "なし", "left": "左", "center": "真ん中", "right": "右"][rawValue] ?? rawValue }
}

enum HairTie: String, AvatarOption {
    case down, ponytail, twinTails, bun
    var label: String { ["down": "下ろしている", "ponytail": "ポニーテール", "twinTails": "ツインテール", "bun": "おだんご"][rawValue] ?? rawValue }
}

/// 眉の太さ・唇の厚さで共用
enum Thickness: String, AvatarOption {
    case thin, normal, thick
    var label: String { ["thin": "細い", "normal": "ふつう", "thick": "太い"][rawValue] ?? rawValue }
}

/// 目の大きさ・鼻の大きさで共用
enum SizeLevel: String, AvatarOption {
    case small, normal, large
    var label: String { ["small": "小さい", "normal": "ふつう", "large": "大きい"][rawValue] ?? rawValue }
}

enum BrowShape: String, AvatarOption {
    case straight, arched, angled, down
    var label: String { ["straight": "まっすぐ", "arched": "アーチ", "angled": "上がり眉", "down": "下がり眉"][rawValue] ?? rawValue }
}

enum EyeTilt: String, AvatarOption {
    case droopy, normal, upturned
    var label: String { ["droopy": "たれ目", "normal": "ふつう", "upturned": "つり目"][rawValue] ?? rawValue }
}

enum EyeColor: String, AvatarOption {
    case black, darkBrown, brown, blue, green, gray
    var label: String {
        ["black": "黒", "darkBrown": "こげ茶", "brown": "茶", "blue": "青", "green": "緑", "gray": "グレー"][rawValue] ?? rawValue
    }
    var color: Color {
        switch self {
        case .black: Color(hex: 0x1E1B1F)
        case .darkBrown: Color(hex: 0x4A2F22)
        case .brown: Color(hex: 0x8B5E3C)
        case .blue: Color(hex: 0x4C86C9)
        case .green: Color(hex: 0x4F9A6B)
        case .gray: Color(hex: 0x8A939C)
        }
    }
    var swatch: Color? { color }
}

enum Mustache: String, AvatarOption {
    case none, thin, thick
    var label: String { ["none": "なし", "thin": "うすい", "thick": "濃い"][rawValue] ?? rawValue }
}

enum Beard: String, AvatarOption {
    case none, stubble, full
    var label: String { ["none": "なし", "stubble": "無精ひげ", "full": "フルひげ"][rawValue] ?? rawValue }
}

enum Glasses: String, AvatarOption {
    case none, square, round, sunglasses
    var label: String { ["none": "なし", "square": "四角メガネ", "round": "丸メガネ", "sunglasses": "サングラス"][rawValue] ?? rawValue }
}

enum Hat: String, AvatarOption {
    case none, cap, beanie, hat
    var label: String { ["none": "なし", "cap": "キャップ", "beanie": "ニット帽", "hat": "ハット"][rawValue] ?? rawValue }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
