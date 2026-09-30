import Foundation

/// 番号体系。階層パスから 1 本のコード文字列を導き、
/// それをファイル名・フォルダ名の先頭に付けて AI と grep の検索キーにする。
///
///     3      1      5      2
///     │      │      │      └ 保険   第3階層 seg=2
///     │      │      └─────── 旅行   第2階層 seg=5
///     │      └────────────── 生活   第1階層 seg=1
///     └───────────────────── Areas  PARA 層
///
/// 実体はあくまで階層構造で、コードは派生値。親を付け替えたら再計算する。
enum ParaCode {

    /// 親のコードに自分の seg を連結する。親が nil なら PARA の先頭桁が起点。
    static func compose(parentCode: String?, para: Para, seg: Int) -> String {
        let prefix = parentCode ?? String(para.leadingDigit)
        return prefix + String(seg)
    }

    /// ルート自身のコード（Journal "1" / Projects "2" / Areas "3" / Resources "4" / Archives "5"）。
    static func rootCode(_ para: Para) -> String { String(para.leadingDigit) }

    /// 親のパスに自分のタイトルを足す。
    static func compose(parentPath: String?, para: Para, title: String) -> String {
        let prefix = parentPath ?? "/\(para.title)"
        return prefix + "/" + title
    }

    /// 同階層の兄弟から次に空いている seg を選ぶ。1 桁に収まらなければ以降は 2 桁以上になる。
    static func nextSeg(usedBy siblings: [Node]) -> Int {
        let used = Set(siblings.map(\.seg))
        var candidate = 1
        while used.contains(candidate) { candidate += 1 }
        return candidate
    }

    /// ノートのファイル名を組み立てる。
    /// journal と knowledge は時刻そのものが識別子（3152_202609191330.md）。
    /// knowledge は「いつ時点の自分の傾向か」が意味を持つので、ジャーナルと同じ日付規則にする。
    /// raw はタイトルのスラグ（3152_海外旅行保険の比較.md）。
    static func filename(code: String, layer: Layer, title: String, occurredAt: Date) -> String {
        switch layer {
        case .journal, .knowledge:
            return "\(code)_\(Format.fileTimestamp.string(from: occurredAt)).md"
        case .raw:
            return "\(code)_\(slug(title)).md"
        }
    }

    /// ファイル名に使えるようタイトルを均す。日本語はそのまま残す。
    static func slug(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\?%*:|\"<>.\n\t")
        let cleaned = title
            .components(separatedBy: forbidden)
            .joined()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        let trimmed = String(cleaned.prefix(48))
        return trimmed.isEmpty ? "untitled" : trimmed
    }
}
