import Foundation
import SwiftUI

// MARK: - PARA

/// Tiago Forte の PARA。話題ではなく「今の自分との関わり度合い」で分ける。
/// 先頭の `journal` は PARA の外にある、どこにも振り分けない日々の記録の置き場。
/// `leadingDigit` がコード体系の先頭桁になる（Journal 1xx / Projects 2xx / Areas 3xx / ...）。
enum Para: String, CaseIterable, Identifiable, Codable {
    case journal
    case projects
    case areas
    case resources
    case archives

    var id: String { rawValue }

    var leadingDigit: Int {
        switch self {
        case .journal: return 1
        case .projects: return 2
        case .areas: return 3
        case .resources: return 4
        case .archives: return 5
        }
    }

    /// ルート直下にノートを置けるか。PARA の 4 つはどこかのフォルダを選ばせるが、
    /// ふつうのジャーナルは分類しないこと自体が目的なので、ルートがそのまま置き場になる。
    var acceptsNotesAtRoot: Bool { self == .journal }

    var title: String {
        switch self {
        case .journal: return "Journal"
        case .projects: return "Projects"
        case .areas: return "Areas"
        case .resources: return "Resources"
        case .archives: return "Archives"
        }
    }

    var subtitle: String {
        switch self {
        case .journal: return String(localized: "Everyday journal")
        case .projects: return String(localized: "Short-term projects")
        case .areas: return String(localized: "Ongoing responsibilities")
        case .resources: return String(localized: "Interests and learning")
        case .archives: return String(localized: "Finished and stored")
        }
    }

    var symbol: String {
        switch self {
        case .journal: return "book"
        case .projects: return "target"
        case .areas: return "circle.hexagongrid"
        case .resources: return "books.vertical"
        case .archives: return "archivebox"
        }
    }

    var tint: Color {
        switch self {
        case .journal: return .pink
        case .projects: return .orange
        case .areas: return .blue
        case .resources: return .green
        case .archives: return .gray
        }
    }
}

// MARK: - ノートの 3 種類

/// 生データ（raw）・ジャーナル（journal）と、その 2 つから調合する自分の傾向（knowledge）。
/// 原本（raw）を書き換えないので、後から分類を変えても情報が失われない。
enum Layer: String, CaseIterable, Identifiable, Codable {
    case raw
    case knowledge
    case journal

    var id: String { rawValue }

    var directoryName: String { rawValue }

    /// 画面に出す名前。ディレクトリ名（raw / knowledge / journal）は書き出しとの互換のため変えない。
    var title: String {
        switch self {
        case .raw: return String(localized: "Raw Data")
        case .knowledge: return String(localized: "My Patterns")
        case .journal: return String(localized: "Journal")
        }
    }

    var summary: String {
        switch self {
        case .raw: return String(localized: "A place for raw data: expert information, links, and sources. Originals are never rewritten")
        case .knowledge: return String(localized: "Your own patterns, blended from raw data and journals")
        case .journal: return String(localized: "Records of a specific day and time")
        }
    }

    var symbol: String {
        switch self {
        case .raw: return "tray.full"
        case .knowledge: return "lightbulb"
        case .journal: return "book.closed"
        }
    }
}

// MARK: - ノード（仮想ディレクトリ）

/// 仮想ディレクトリの 1 階層。実ファイルシステムは持たない。
/// `code` と `path` は親子関係から導出した値をマテリアライズして保持する
/// （`code LIKE '115%'` の前方一致で部分木を一撃で引くため）。
struct Node: Identifiable, Hashable {
    var id: String
    var parentID: String?
    var para: Para
    /// この階層に割り当てられた番号。親の code に連結されて自分の code になる。
    var seg: Int
    /// 例) "3152"
    var code: String
    /// 例) "/Areas/生活/旅行/保険"
    var path: String
    var title: String
    var depth: Int
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    var displayName: String { "\(code) \(title)" }
}

// MARK: - ノート

struct Note: Identifiable, Hashable {
    var id: String
    var nodeID: String
    var layer: Layer
    /// 例) "3152_202609191330.md"
    var filename: String
    var title: String
    /// Markdown 原文。DB 固有形式にはしない。
    var body: String
    var sourceURL: String?
    /// その日その時。カレンダーが並べる軸。
    var occurredAt: Date
    /// "yyyy-MM-dd"。カレンダーの日付索引。
    var dayKey: String
    var createdAt: Date
    var updatedAt: Date

    /// 一覧に出す 1 行プレビュー。見出し記法と装飾を落とす。
    var preview: String {
        body
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# *->` \t")) }
            .first(where: { !$0.isEmpty && $0 != title }) ?? ""
    }
}

/// カレンダーやツリーの一覧で、ノートと所属ノードを一緒に見せるための組。
struct NoteWithNode: Identifiable, Hashable {
    var note: Note
    var node: Node

    var id: String { note.id }
}

// MARK: - チャット

struct Message: Identifiable, Hashable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    var id: String
    var sessionID: String
    var role: Role
    var content: String
    /// このメッセージから生成されたジャーナルがあれば、その id。
    var noteID: String?
    var createdAt: Date
}

/// 過去の対話 1 本。表は持たず、`messages` を `session_id` でまとめて作る。
struct ChatSession: Identifiable, Hashable {
    var id: String
    /// 最初の自分の発言。一覧の見出しに使う。
    var title: String
    var startedAt: Date
    var updatedAt: Date
}

// MARK: - 共通フォーマッタ

enum Format {
    /// ジャーナルのファイル名に使う "yyyyMMddHHmm"。
    static let fileTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMddHHmm"
        return formatter
    }()

    /// カレンダー索引に使う "yyyy-MM-dd"。
    static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayKey(for date: Date) -> String { dayKey.string(from: date) }
}
