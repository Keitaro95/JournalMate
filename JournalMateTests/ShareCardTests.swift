import Foundation
import Testing
@testable import JournalMate

/// 共有用の画像。大きさ・ページ分け・載せないもの。
@MainActor
struct ShareCardTests {

    private let date = Format.fileTimestamp.date(from: "202610061230")!

    @Test func shortJournalIsOnePageOf1080x1350() {
        let content = ShareCardContent(date: date, title: "海", body: "今日は海に行った。\n風が強かった。")
        let images = ShareCardRenderer.render(content, includesAppName: true)
        #expect(images.count == 1)
        for image in images {
            #expect(image.size.width * image.scale == 1080)
            #expect(image.size.height * image.scale == 1350)
        }
    }

    @Test func longJournalIsSplitIntoPages() {
        let body = (1...30).map { "\($0) 行目。今日あったことを書いている。" }.joined(separator: "\n")
        let pages = ShareCardRenderer.paginate(ShareCardContent(date: date, title: "長い日", body: body))
        #expect((2...4).contains(pages.count))
        #expect(pages.allSatisfy { $0.pageCount == pages.count })
        #expect(!pages.flatMap(\.blocks).contains(.ellipsis))
        // 行は抜けずに、順番どおりに入っている。
        let lines = pages.flatMap(\.blocks).compactMap { block -> String? in
            if case let .line(line) = block { return line }
            return nil
        }
        #expect(lines == body.components(separatedBy: "\n"))
    }

    @Test func veryLongJournalStopsAtFourPagesWithEllipsis() {
        let body = (1...400).map { "\($0) 行目" }.joined(separator: "\n")
        let pages = ShareCardRenderer.paginate(ShareCardContent(date: date, title: "とても長い日", body: body))
        #expect(pages.count == ShareCardRenderer.maxPages)
        #expect(pages.last?.blocks.last == .ellipsis)
    }

    /// 画像の元にはノートのパスもフォルダも渡らない（`ShareCardContent` に持たせていない）。
    @Test func onlyDateTitleAndBodyAreOnTheCard() {
        let pages = ShareCardRenderer.paginate(ShareCardContent(date: date, title: "題", body: "本文"))
        #expect(pages.first?.blocks == [.header(date: date, title: "題"), .line("本文")])
    }
}
