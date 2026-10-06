import SwiftUI
import UIKit

/// 共有用の画像に載せる中身。ノートのパス・フォルダ・タグは持たせない
/// （フォルダ名に仕事や生活の中身が出ることがあるので、画像に載らないようにする）。
struct ShareCardContent: Equatable {
    /// 編集日（`note.updatedAt`）。
    var date: Date
    var title: String
    var body: String
}

/// ジャーナルを Instagram / X 向けの 4:5 の画像にする。
///
/// 1 ページは 360×450pt を 3 倍で描いて 1080×1350px にする。
/// 本文は Markdown の行ごとに高さを測ってページに詰め、収まらない分は次のページへ送る。
/// X に一度に載せられるのが 4 枚なので、それより長いときは 4 枚目の最後を「…」で切る。
@MainActor
enum ShareCardRenderer {

    static let pageSize = CGSize(width: 360, height: 450)
    static let scale: CGFloat = 3
    static let maxPages = 4

    static let horizontalPadding: CGFloat = 28
    static let topPadding: CGFloat = 32
    static let bottomPadding: CGFloat = 20
    static let footerHeight: CGFloat = 28
    static let blockSpacing: CGFloat = 8

    static var contentWidth: CGFloat { pageSize.width - horizontalPadding * 2 }
    /// 本文に使える高さ。下の 1 行（アプリ名・ページ番号）の分は、出さないときも空けておく。
    static var contentHeight: CGFloat { pageSize.height - topPadding - bottomPadding - footerHeight }

    static func render(_ content: ShareCardContent, includesAppName: Bool) -> [UIImage] {
        paginate(content).enumerated().compactMap { index, page in
            let renderer = ImageRenderer(content: ShareCardPage(
                page: page, pageNumber: index + 1, pageCount: page.pageCount,
                includesAppName: includesAppName))
            renderer.scale = scale
            renderer.proposedSize = ProposedViewSize(pageSize)
            return renderer.uiImage
        }
    }

    /// 行をページに詰める。テストからも呼ぶ。
    static func paginate(_ content: ShareCardContent) -> [SharePage] {
        let blocks = [ShareBlock.header(date: content.date, title: content.title)]
            + content.body
                .trimmingCharacters(in: .newlines)
                .components(separatedBy: "\n")
                .map(ShareBlock.line)
        let ellipsisHeight = height(of: .ellipsis)

        var pages: [[ShareBlock]] = [[]]
        var used: CGFloat = 0
        var isTruncated = false

        for block in blocks {
            let blockHeight = height(of: block)
            let needed = pages[pages.count - 1].isEmpty ? blockHeight : used + blockSpacing + blockHeight
            if needed <= contentHeight || pages[pages.count - 1].isEmpty {
                // 1 ページより長い 1 行は、そのページに入れて下を切る（`ShareCardPage` で clipped）。
                pages[pages.count - 1].append(block)
                used = needed
            } else if pages.count < maxPages {
                pages.append([block])
                used = blockHeight
            } else {
                isTruncated = true
                break
            }
        }

        if isTruncated {
            // 「…」の入る場所を空ける。最後のページの行を、入るまで後ろから外す。
            var last = pages.removeLast()
            var lastUsed = used
            while last.count > 1, lastUsed + blockSpacing + ellipsisHeight > contentHeight {
                let removed = last.removeLast()
                lastUsed -= height(of: removed) + blockSpacing
            }
            last.append(.ellipsis)
            pages.append(last)
        }

        return pages.map { SharePage(blocks: $0, pageCount: pages.count) }
    }

    private static func height(of block: ShareBlock) -> CGFloat {
        let renderer = ImageRenderer(content: ShareBlockView(block: block)
            .frame(width: contentWidth, alignment: .leading)
            .shareCardStyle())
        renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)
        return renderer.uiImage?.size.height ?? 0
    }
}

struct SharePage: Equatable {
    var blocks: [ShareBlock]
    var pageCount: Int
}

enum ShareBlock: Equatable {
    /// 1 ページ目の頭。日付と題名。
    case header(date: Date, title: String)
    /// 本文の Markdown の 1 行。
    case line(String)
    /// 長すぎて切ったしるし。
    case ellipsis
}

private struct ShareBlockView: View {
    let block: ShareBlock

    var body: some View {
        switch block {
        case let .header(date, title):
            VStack(alignment: .leading, spacing: 8) {
                Text(date, format: .dateTime.year().month().day())
                    .appFont(.caption1)
                    .foregroundStyle(.secondary)
                Text(title)
                    .appFont(.title2, weight: .semibold)
                Divider()
            }
        case let .line(line):
            MarkdownLine(line: line)
        case .ellipsis:
            Text(verbatim: "…")
                .appFont(.body)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ShareCardPage: View {
    let page: SharePage
    let pageNumber: Int
    let pageCount: Int
    let includesAppName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: ShareCardRenderer.blockSpacing) {
                ForEach(Array(page.blocks.enumerated()), id: \.offset) { _, block in
                    ShareBlockView(block: block)
                }
            }
            .frame(width: ShareCardRenderer.contentWidth,
                   height: ShareCardRenderer.contentHeight,
                   alignment: .topLeading)
            .clipped()

            footer
                .frame(height: ShareCardRenderer.footerHeight, alignment: .bottom)
        }
        .padding(.horizontal, ShareCardRenderer.horizontalPadding)
        .padding(.top, ShareCardRenderer.topPadding)
        .padding(.bottom, ShareCardRenderer.bottomPadding)
        .frame(width: ShareCardRenderer.pageSize.width, height: ShareCardRenderer.pageSize.height)
        .background(Color.white)
        .shareCardStyle()
    }

    /// 本文の邪魔をしないよう、小さく薄く右下に 1 行。1 枚だけ転送されても名前が残るよう各ページに入れる。
    private var footer: some View {
        HStack(spacing: 6) {
            if pageCount > 1 {
                Text(verbatim: "\(pageNumber)/\(pageCount)")
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if includesAppName {
                Image("ShareMark")
                    .resizable()
                    .frame(width: 14, height: 14)
                    .clipShape(.rect(cornerRadius: 3.5))
                Text("Journaled with JournalMate")
            }
        }
        .appFont(.caption2)
        .foregroundStyle(.tertiary)
    }
}

private extension View {
    /// 端末がダークモードでも文字サイズを大きくしていても、共有先で同じに見えるよう固定する。
    func shareCardStyle() -> some View {
        self
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large)
    }
}
