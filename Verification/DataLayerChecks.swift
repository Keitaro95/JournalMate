import Foundation

@MainActor var failures = 0
@MainActor func check(_ label: String, _ actual: String, _ expected: String) {
    let ok = actual == expected
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(label): \(actual)\(ok ? "" : "  (expected \(expected))")")
}
@MainActor func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    if !condition { failures += 1 }
    print("\(condition ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : ": \(detail)")")
}

@main
struct Harness {
    @MainActor
    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let store = try Store.inMemory()

        // --- PARA ルート ---
        check("ルートは Journal + PARA の 5 件", store.roots.count == 5, "\(store.roots.count)")
        check("先頭は Journal", store.roots.first?.para.rawValue ?? "", "journal")
        check("Journal の先頭桁", store.root(for: .journal)?.code ?? "", "1")
        check("Projects の先頭桁", store.root(for: .projects)?.code ?? "", "2")
        check("Areas の先頭桁", store.root(for: .areas)?.code ?? "", "3")
        check("Resources の先頭桁", store.root(for: .resources)?.code ?? "", "4")

        // --- 階層とコード（seg を明示指定：ユーザーの例 3152 を再現）---
        let areas = store.root(for: .areas)!
        let life = try store.createFolder(under: areas, title: "生活", seg: 1)
        let travel = try store.createFolder(under: life, title: "旅行", seg: 5)
        let insurance = try store.createFolder(under: travel, title: "保険", seg: 2)
        check("3152 を再現", insurance.code, "3152")
        check("パス", insurance.path, "/Areas/生活/旅行/保険")

        // --- 自動採番 ---
        let hobby = try store.createFolder(under: life, title: "趣味")
        check("空き番号を自動採番", hobby.code, "311")

        // --- ノート ---
        let when = Format.fileTimestamp.date(from: "202609191330")!
        let note = try store.createNote(in: insurance, layer: .journal,
                                        title: "海外旅行保険を調べた",
                                        body: "# 調べたこと\n- クレカ付帯で足りるか\n- 治療費の上限",
                                        occurredAt: when)
        check("ジャーナルのファイル名", note.filename, "3152_202609191330.md")

        let raw = try store.createNote(in: insurance, layer: .raw,
                                       title: "専門家の比較記事", body: "出典: example.com",
                                       occurredAt: when.addingTimeInterval(-86_400))
        check("raw のファイル名", raw.filename, "3152_専門家の比較記事.md")
        check("knowledge はジャーナルと同じ日付規則",
              ParaCode.filename(code: "3152", layer: .knowledge, title: "傾向", occurredAt: when),
              "3152_202609191330.md")

        // --- 自分の傾向の材料 ---
        let material = try KnowledgeGenerator.material(in: insurance, store: store)
        check("傾向の材料: 生データ", material.raw.map(\.note.id) == [raw.id])
        check("傾向の材料: ジャーナル", material.journals.map(\.note.id) == [note.id])
        let patternSource = KnowledgeGenerator.sourceText(material)
        check("傾向の材料: 生データが先、ジャーナルは日付付き",
              (patternSource.range(of: "専門家の比較記事")?.lowerBound ?? patternSource.endIndex)
                < (patternSource.range(of: "2026-09-19 海外旅行保険を調べた")?.lowerBound ?? patternSource.startIndex))

        // --- カレンダー索引 ---
        let sameDay = try store.notes(on: when)
        check("その日のノートを日付で引ける", sameDay.count == 1, "\(sameDay.count)")
        check("PARA タグが付いてくる", sameDay.first?.node.para == .areas)

        let markers = try store.dayMarkers(from: when.addingTimeInterval(-86400 * 30),
                                           to: when.addingTimeInterval(86400 * 30))
        check("カレンダー装飾", markers["2026-09-19"]?.count == 1, "\(markers["2026-09-19"]?.count ?? -1)")
        check("別の日は別のマーカー", markers["2026-09-18"]?.count == 1)
        check("装飾の PARA", markers["2026-09-19"]?.para == .areas)

        // --- カレンダーの絞り込み（PARA タブ＋フォルダのチェック）---
        // ここだけ別の DB を使う。あとの往復検証がノート件数を数えているので混ぜない。
        let filterStore = try Store.inMemory()
        let filterProjects = filterStore.root(for: .projects)!
        let moving = try filterStore.createFolder(under: filterProjects, title: "引っ越し", seg: 1)
        let study = try filterStore.createFolder(under: filterProjects, title: "資格の勉強", seg: 2)
        let filterAreas = filterStore.root(for: .areas)!
        let health = try filterStore.createFolder(under: filterAreas, title: "健康", seg: 1)
        _ = try filterStore.createNote(in: moving, layer: .journal, title: "内見に行った",
                                       body: "日当たりは良い", occurredAt: when)
        _ = try filterStore.createNote(in: study, layer: .journal, title: "過去問を 1 年分",
                                       body: "午後がきつい", occurredAt: when)
        _ = try filterStore.createNote(in: health, layer: .journal, title: "5km 走った",
                                       body: "膝は平気", occurredAt: when.addingTimeInterval(-86_400))

        let range = (when.addingTimeInterval(-86400 * 30), when.addingTimeInterval(86400 * 30))
        check("絞り込み無しなら全部の PARA",
              try filterStore.notes(on: when, codePrefixes: []).count == 2,
              "\(try filterStore.notes(on: when, codePrefixes: []).count)")
        check("PARA ルートの前方一致でその PARA だけ",
              try filterStore.notes(on: when, codePrefixes: [filterProjects.code]).count == 2)
        check("別の PARA を選ぶとその日は空",
              try filterStore.notes(on: when, codePrefixes: [filterAreas.code]).isEmpty)
        check("チェックしたフォルダだけ",
              try filterStore.notes(on: when, codePrefixes: [moving.code]).count == 1)
        check("複数チェックは和集合",
              try filterStore.notes(on: when, codePrefixes: [moving.code, study.code]).count == 2)
        check("空振りする前方一致なら 0 件",
              try filterStore.notes(on: when, codePrefixes: ["999"]).isEmpty)

        let projectMarkers = try filterStore.dayMarkers(from: range.0, to: range.1,
                                                        codePrefixes: [filterProjects.code])
        check("装飾も同じ絞り込みで数える", projectMarkers["2026-09-19"]?.count == 2,
              "\(projectMarkers["2026-09-19"]?.count ?? -1)")
        check("絞り込むと他 PARA の日は消える", projectMarkers["2026-09-18"] == nil)
        check("装飾の PARA も絞り込みに従う", projectMarkers["2026-09-19"]?.para == .projects)

        let folderMarkers = try filterStore.dayMarkers(from: range.0, to: range.1,
                                                       codePrefixes: [moving.code])
        check("チェック 1 つなら装飾もその 1 件", folderMarkers["2026-09-19"]?.count == 1)

        // --- 日本語全文検索（trigram）---
        check("日本語の部分一致", try store.search("クレカ付帯").count == 1)
        check("見出しでも当たる", try store.search("海外旅行").count == 1)
        check("無関係な語は当たらない", try store.search("確定申告").isEmpty)
        check("2 文字は LIKE にフォールバック", try store.search("保険").count == 1)

        // --- 前方一致で部分木 ---
        check("code 前方一致で部分木", try store.subtree(codePrefix: "315").count == 2)

        // --- 非破壊の再分類：Areas → Resources へ移す ---
        let resources = store.root(for: .resources)!
        try store.move(travel, under: resources)
        let movedInsurance = try store.node(id: insurance.id)!
        check("移動で code を引き直す", movedInsurance.code, "412")
        check("移動で para も伝播", movedInsurance.para == .resources)
        check("移動で path も引き直す", movedInsurance.path, "/Resources/旅行/保険")

        let movedNotes = try store.notes(in: movedInsurance, layer: .journal)
        check("ファイル名も振り直す", movedNotes.first?.filename ?? "", "412_202609191330.md")
        check("本文は書き換えない（非破壊）",
              movedNotes.first?.body.contains("クレカ付帯") == true)

        // --- さらに入れ子へ移す：子孫まで再帰的に引き直されるか ---
        let learning = try store.createFolder(under: resources, title: "学び")
        check("兄弟の空き番号", learning.code, "42")
        try store.move(try store.node(id: travel.id)!, under: learning)
        let deep = try store.node(id: insurance.id)!
        check("孫まで code を引き直す", deep.code, "4212")
        check("孫まで path を引き直す", deep.path, "/Resources/学び/旅行/保険")
        check("孫の depth", "\(deep.depth)", "3")
        check("自分の子孫には移せない",
              { try? store.move(learning, under: deep); return (try? store.node(id: learning.id))?.code == "42" }())

        // --- ソフト削除 ---
        try store.deleteNote(raw)
        check("削除したノートは一覧から消える",
              try store.notes(in: deep, layer: .raw).isEmpty)

        // --- Vault 書き出し ---
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let vault = try VaultExporter.exportVault(from: store, to: tmp)
        let exported = vault.appendingPathComponent("Resources/学び/旅行/保険/journal/4212_202609191330.md")
        check("実 .md が書き出される", FileManager.default.fileExists(atPath: exported.path))
        let text = try String(contentsOf: exported, encoding: .utf8)
        check("frontmatter に code", text.contains("code: 4212"))
        check("frontmatter に layer", text.contains("layer: journal"))
        check("frontmatter に tags", text.contains("tags: [resources, journal"))
        check("復元用の写しが Vault に入る", FileManager.default.fileExists(
            atPath: vault.appendingPathComponent(VaultExporter.backupFilename).path))

        // --- 対話の履歴 ---
        try store.appendMessage(sessionID: "s1", role: .user, content: "バックアップに入れない話")
        try store.appendMessage(sessionID: "s1", role: .assistant, content: "はい")
        try store.appendMessage(sessionID: "s2", role: .assistant, content: "AI から始まった対話")
        try store.appendMessage(sessionID: "s2", role: .user, content: "二本目")
        let sessions = try store.chatSessions()
        check("対話ごとにまとまる", sessions.count == 2, "\(sessions.count)")
        check("見出しは最初の自分の発言", sessions.first { $0.id == "s2" }?.title ?? "", "二本目")
        check("対話の中は書いた順", try store.messages(sessionID: "s1").map(\.content).joined(separator: ","),
              "バックアップに入れない話,はい")
        try store.deleteChatSession(id: "s2")
        check("対話を消せる", try store.chatSessions().map(\.id) == ["s1"])

        // --- zip からの復元（アプリを入れ直した想定：まっさらな DB に戻す）---
        let zip = try VaultExporter.exportZip(from: store)
        let backupCopy = try VaultExporter.extractBackup(from: zip)
        let backupBytes = try Data(contentsOf: backupCopy)
        check("バックアップに対話の本文が残らない",
              backupBytes.range(of: Data("バックアップに入れない話".utf8)) == nil)
        check("バックアップは 1 ファイルで完結（-wal が無い）", !FileManager.default.fileExists(
            atPath: vault.appendingPathComponent(VaultExporter.backupFilename + "-wal").path))
        let fresh = try Store.inMemory()
        _ = try fresh.createNote(in: fresh.root(for: .areas)!, layer: .journal,
                                 title: "入れ直し直後に書いたもの", body: "", occurredAt: Date())
        try fresh.appendMessage(sessionID: "local", role: .user, content: "この端末の対話")
        let restoredCount = try fresh.restore(fromBackup: VaultExporter.extractBackup(from: zip))
        let originalCount = try store.recentNotes(limit: 10_000).count
        check("zip から全ノートが戻る", restoredCount == originalCount, "\(restoredCount) / \(originalCount)")
        check("フォルダ構造が戻る", try fresh.allNodes().map(\.path) == store.allNodes().map(\.path))
        check("ジャーナルのファイル名が戻る",
              try fresh.notes(on: when).first?.note.filename ?? "", "4212_202609191330.md")
        check("復元後も全文検索が効く", try !fresh.search("海外旅行").isEmpty)
        check("復元前の中身は置き換わる", try fresh.search("入れ直し直後").isEmpty)
        check("復元してもこの端末の対話は残る", try fresh.chatSessions().map(\.id) == ["local"])
        check("削除済みは削除済みのまま（一覧に出ない）", try fresh.notes(in: deep, layer: .raw).isEmpty)
        check("展開したフォルダからも戻せる",
              (try? fresh.restore(fromBackup: VaultExporter.extractBackup(from: vault))) == originalCount)
        check("関係ないファイルは弾く", (try? VaultExporter.extractBackup(from: exported)) == nil)

        // --- ファイル名の日付（メモ作成日を運ぶ唯一の経路）---
        let stamped = MemoImporter.timestamp(inFilename: "202401151045_会議のメモ.txt")
        check("ファイル名の yyyyMMddHHmm を読む",
              stamped.map { Format.fileTimestamp.string(from: $0.date) } ?? "", "202401151045")
        check("日付のあとが見出しになる", stamped?.remainder ?? "", "会議のメモ")
        check("ハイフン区切りも読む",
              MemoImporter.timestamp(inFilename: "2026-09-19 13-30 旅行.md")
                  .map { Format.fileTimestamp.string(from: $0.date) } ?? "", "202609191330")
        check("日付なしは nil", MemoImporter.timestamp(inFilename: "買い物リスト.txt") == nil)
        check("数字が続くものを日付と誤認しない",
              MemoImporter.timestamp(inFilename: "202609192件のこと.txt") == nil)

        // --- 外部メモの取り込み ---
        let source = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("仕事"),
                                                withIntermediateDirectories: true)
        try "会議のメモ\n- 予算の話\n- 次は来週"
            .write(to: source.appendingPathComponent("仕事/202401151045_会議のメモ.txt"),
                   atomically: true, encoding: .utf8)
        try "買い物リスト\n- 牛乳"
            .write(to: source.appendingPathComponent("買い物リスト.txt"),
                   atomically: true, encoding: .utf8)

        let scanned = try MemoImporter.scan(directory: source)
        check("2 件読み取る", scanned.memos.count == 2, "\(scanned.memos.count)")

        let inboxStore = try Store.inMemory()
        let first = try MemoImporter.importMemos(scanned, into: inboxStore)
        check("2 件とも入る", first.imported == 2, "\(first.imported)")
        check("作成日を復元できたのは 1 件", first.withOriginalDate == 1, "\(first.withOriginalDate)")
        check("残り 1 件は書き出した日で代用", first.withSubstitutedDate == 1,
              "\(first.withSubstitutedDate)")

        let workInbox = try inboxStore.allNodes().first { $0.path == "/Resources/\(MemoImporter.inboxTitle)/仕事" }
        check("元のフォルダ名が受信箱の下に残る", workInbox != nil)
        let meeting = try inboxStore.notes(in: workInbox!, layer: .raw).first
        check("raw として入る", meeting != nil)
        check("メモ作成日がそのまま occurredAt になる",
              meeting.map { Format.fileTimestamp.string(from: $0.occurredAt) } ?? "", "202401151045")
        check("1 行目が見出しになる", meeting?.title ?? "", "会議のメモ")
        check("見出しは本文から落とす", meeting?.body ?? "", "- 予算の話\n- 次は来週")
        check("その日のカレンダーから引ける",
              try inboxStore.notes(on: Format.fileTimestamp.date(from: "202401151045")!).count == 1)

        let second = try MemoImporter.importMemos(scanned, into: inboxStore)
        check("二度目は重複しない", second.imported == 0 && second.skipped == 2,
              "imported \(second.imported) / skipped \(second.skipped)")

        // --- 書き出した Vault を読み戻す（往復）---
        let reimported = try Store.inMemory()
        let roundTrip = try MemoImporter.importMemos(
            try MemoImporter.scan(directory: vault), into: reimported)
        check("Vault の .md を読み戻す", roundTrip.imported == 1, "\(roundTrip.imported)")
        check("frontmatter から日時を戻す",
              roundTrip.dateSources[.frontmatter] == 1)
        let restored = try reimported.allNodes().first { $0.path == "/Resources/学び/旅行/保険" }
        check("frontmatter の path に戻る", restored != nil)
        let restoredNote = try restored.map { try reimported.notes(in: $0, layer: .journal) }?.first
        check("layer も戻る", restoredNote != nil)
        check("占有時刻も戻る",
              restoredNote.map { Format.fileTimestamp.string(from: $0.occurredAt) } ?? "",
              "202609191330")
        check("受信箱には落ちない",
              try reimported.allNodes().allSatisfy { !MemoImporter.inboxTitles.contains($0.title) })

        // --- 表示言語を切り替えても受信箱を見失わない ---
        let switchedStore = try Store.inMemory()
        let otherTitle = MemoImporter.inboxTitles.first { $0 != MemoImporter.inboxTitle }!
        let oldInbox = try switchedStore.createFolder(
            under: switchedStore.root(for: MemoImporter.inboxPara)!, title: otherTitle)
        check("別の言語で作った受信箱も見つかる", try switchedStore.inboxNode()?.id ?? "", oldInbox.id)
        check("既存の受信箱の名前を使い続ける",
              try switchedStore.inboxTitle(in: MemoImporter.inboxPara), otherTitle)

        // --- 課金: 解放判定（純粋関数） ---
        check("契約者は回数を数えない",
              Usage.access(to: .journalExtract, isPro: true, usedThisMonth: 999) == .pro)
        check("オンボーディングの抽出は 1 回だけ無料",
              Usage.access(to: .onboardingExtract, isPro: false, usedThisMonth: 0)
                == .free(remaining: 1))
        check("オンボーディングの抽出を使い切ると Paywall",
              Usage.access(to: .onboardingExtract, isPro: false, usedThisMonth: 1) == .locked)
        check("対話は Pro 専用",
              Usage.access(to: .aiChat, isPro: false, usedThisMonth: 0) == .locked)
        check("ジャーナル抽出は Pro 専用（無料枠なし）",
              Usage.access(to: .journalExtract, isPro: false, usedThisMonth: 0) == .locked)
        check("手で書くのも Pro 専用",
              Usage.access(to: .journalWrite, isPro: false, usedThisMonth: 0) == .locked)
        check("無料枠を持つのはオンボーディングの体験だけ",
              ProFeature.allCases.filter { $0.monthlyFreeLimit > 0 } == [.onboardingChat, .onboardingExtract])
        check("オンボーディングの枠は Paywall に並べない",
              !ProFeature.onboardingChat.isListed && !ProFeature.onboardingExtract.isListed
                && ProFeature.aiChat.isListed && ProFeature.journalWrite.isListed)

        // --- 課金: 消費の記録 ---
        let meter = try Store.inMemory()
        check("初期値は 0", try meter.usedThisMonth(.journalExtract) == 0)
        try meter.consume(.journalExtract)
        try meter.consume(.journalExtract)
        check("消費が積まれる", try meter.usedThisMonth(.journalExtract) == 2,
              "\(try meter.usedThisMonth(.journalExtract))")
        check("機能ごとに別勘定", try meter.usedThisMonth(.aiChat) == 0)

        let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        try meter.consume(.journalExtract, on: lastMonth)
        check("先月ぶんは今月に混ざらない", try meter.usedThisMonth(.journalExtract) == 2,
              "\(try meter.usedThisMonth(.journalExtract))")
        check("先月は先月で数える",
              try meter.usedThisMonth(.journalExtract, on: lastMonth) == 1)
        try meter.consume(.onboardingExtract, on: lastMonth)
        check("月が変われば枠が戻る",
              Usage.access(to: .onboardingExtract, isPro: false,
                           usedThisMonth: try meter.usedThisMonth(.onboardingExtract))
                == .free(remaining: 1))

        // --- 呼び先の解決 ---
        let direct = ClaudeClient(apiKey: "sk-ant-test")
        check("BYO キーは Anthropic に直接",
              direct.endpoint.absoluteString, "https://api.anthropic.com/v1/messages")
        check("キーはヘッダに載る", direct.headers["x-api-key"] ?? "", "sk-ant-test")
        let relayed = ClaudeClient(gateway: URL(string: "https://example.com/v1/messages")!,
                                   feature: .journalExtract,
                                   authorize: { _ in "session-token" })
        check("契約者はゲートウェイ経由",
              relayed.endpoint.absoluteString, "https://example.com/v1/messages")
        check("ゲートウェイに API キーを載せない", relayed.headers["x-api-key"] == nil)
        check("appUserID をヘッダに載せない（詐称できるので認証にならない）",
              relayed.headers["X-App-User-Id"] == nil)

        // --- トークンの上限 ---
        check("出力は重み付けされる",
              TokenUsage(input: 1_000, output: 1_000).weighted == 1_000 + 5_000,
              "\(TokenUsage(input: 1_000, output: 1_000).weighted)")
        check("キャッシュ読み出しは割り引く",
              TokenUsage(input: 0, output: 0, cacheRead: 10_000).weighted == 1_000)
        check("足し合わせられる",
              (TokenUsage(input: 1, output: 2) + TokenUsage(input: 3, output: 4))
                == TokenUsage(input: 4, output: 6))

        let day = Format.fileTimestamp.date(from: "202609231200")!
        let next = Format.fileTimestamp.date(from: "202609241200")!
        check("最初は 0", try meter.tokenUsage(on: day).isEmpty)

        try meter.record(TokenUsage(input: 10_000, output: 2_000), on: day)
        try meter.record(TokenUsage(input: 5_000, output: 1_000, cacheRead: 20_000), on: day)
        let today = try meter.tokenUsage(on: day)
        check("入力が積まれる", today.input == 15_000, "\(today.input)")
        check("出力が積まれる", today.output == 3_000, "\(today.output)")
        check("キャッシュも積まれる", today.cacheRead == 20_000, "\(today.cacheRead)")
        check("呼び出し回数を数える", try meter.requestCount(on: day) == 2,
              "\(try meter.requestCount(on: day))")
        check("空の usage は記録しない",
              { try? meter.record(TokenUsage(), on: day)
                return (try? meter.requestCount(on: day)) == 2 }())

        check("日が変われば 0 に戻る", try meter.tokenUsage(on: next).isEmpty)

        let budget = try meter.dailyBudget(on: day, limit: 100_000)
        check("重み付きで消費を数える", budget.used == 15_000 + 15_000 + 2_000, "\(budget.used)")
        check("残量", budget.remaining == 68_000, "\(budget.remaining)")
        check("余裕があれば始められる", budget.canStart)

        let nearLimit = DailyBudget(used: 90_000, limit: 100_000)
        check("残りが余白を切ったら始めさせない", !nearLimit.canStart)
        check("上限ちょうどでも止まる", !DailyBudget(used: 100_000, limit: 100_000).canStart)
        check("使い切ると残量 0", DailyBudget(used: 120_000, limit: 100_000).remaining == 0)

        // --- 応答からトークンを読む ---
        let parsed = ClaudeClient.usage(from: [
            "input_tokens": 120, "output_tokens": 34, "cache_read_input_tokens": 500,
        ])
        check("応答の usage を読む", parsed == TokenUsage(input: 120, output: 34, cacheRead: 500))
        check("欠けている項目は 0",
              ClaudeClient.usage(from: ["input_tokens": 7]) == TokenUsage(input: 7))
        check("usage が無くても落ちない", ClaudeClient.usage(from: nil).isEmpty)

        // --- 無料枠: サーバの数字で上書きする ---
        let sync = try Store.inMemory()
        try sync.consume(.journalExtract)
        check("アプリ側の数え", try sync.usedThisMonth(.journalExtract) == 1)
        // 入れ直して 0 に戻っていても、サーバが 7 と言えば 7 に合わせる。
        try sync.syncUsage(.journalExtract, used: 7)
        check("サーバの数字で上書きする（足さない）",
              try sync.usedThisMonth(.journalExtract) == 7,
              "\(try sync.usedThisMonth(.journalExtract))")
        check("まだ使っていなければ残り 1",
              Usage.access(to: .onboardingExtract, isPro: false,
                           usedThisMonth: try sync.usedThisMonth(.onboardingExtract))
                == .free(remaining: 1))
        try sync.syncUsage(.onboardingExtract, used: 1)
        check("使い切りに合わせれば Paywall",
              Usage.access(to: .onboardingExtract, isPro: false,
                           usedThisMonth: try sync.usedThisMonth(.onboardingExtract)) == .locked)

        // --- 402 の見分け（Paywall を出すため）---
        let refused = ClaudeClient.failure(
            status: 402,
            body: Data(#"{"error":{"type":"subscription_required","message":"今月の無料枠を使い切りました"}}"#.utf8))
        if case .needsPro(let message) = refused {
            check("402 は Pro が要ると分かる形で返す", message, "今月の無料枠を使い切りました")
        } else {
            check("402 は Pro が要ると分かる形で返す", false)
        }
        if case .http(let status, _) = ClaudeClient.failure(status: 500, body: Data()) {
            check("他のエラーはそのまま", status == 500)
        } else {
            check("他のエラーはそのまま", false)
        }

        // --- 429 の見分け（月の上限は待っても戻らないので、日次と別の文言にする）---
        let monthly = ClaudeClient.failure(
            status: 429,
            body: Data(#"{"error":{"type":"budget_exhausted","scope":"monthly"}}"#.utf8))
        if case .monthlyLimitReached(let offersMax) = monthly {
            check("月の上限の 429 は専用の失敗になり、Pro には Max を案内する", offersMax)
        } else {
            check("月の上限の 429 は専用の失敗になり、Pro には Max を案内する", false)
        }
        let monthlyOnMax = ClaudeClient.failure(
            status: 429,
            body: Data(#"{"error":{"type":"budget_exhausted","scope":"monthly"}}"#.utf8),
            model: ClaudeClient.maxModel)
        if case .monthlyLimitReached(let offersMax) = monthlyOnMax {
            check("Max の人には月の上限で Max を案内しない", !offersMax)
        } else {
            check("Max の人には月の上限で Max を案内しない", false)
        }
        let daily = ClaudeClient.failure(
            status: 429,
            body: Data(#"{"error":{"type":"budget_exhausted","scope":"daily"}}"#.utf8))
        if case .http(let status, _) = daily {
            check("日次の 429 はこれまで通り", status == 429)
        } else {
            check("日次の 429 はこれまで通り", false)
        }

        let trialTotal = ClaudeClient.failure(
            status: 429,
            body: Data(#"{"error":{"type":"budget_exhausted","scope":"total"}}"#.utf8))
        if case .trialLimitReached = trialTotal {
            check("トライアルの合計の 429 は専用の失敗になる", true)
        } else {
            check("トライアルの合計の 429 は専用の失敗になる", false)
        }

        // --- プラン（Pro / Max）。数字はゲートウェイの PLANS と揃える ---
        check("Pro は Sonnet", ClaudeClient.model(for: .pro), "claude-sonnet-5")
        check("Max は Opus", ClaudeClient.model(for: .max), "claude-opus-5")
        check("Pro の 1 日の上限", "\(TokenBudget.daily(for: .pro))", "80000")
        check("Max の 1 日の上限は Pro の 2 倍",
              TokenBudget.daily(for: .max) == TokenBudget.daily(for: .pro) * 2)
        // トライアル: Pro の月の上限（60 万）を 7 日に日割りした 14 万を、1 日 2 万に区切る
        check("トライアルは Haiku", ClaudeClient.trialModel, "claude-haiku-4-5-20251001")
        check("トライアルの 1 日の上限は Pro と同じ（サーバ側 TRIAL.daily = 80,000）",
              TokenBudget.trialDaily == TokenBudget.daily && TokenBudget.trialDaily == 80_000)

        // --- ジャーナル化: 保存先の候補（AI 呼び出し以外のすべて）---
        let saveStore = try Store.inMemory()
        let movingFolder = try saveStore.ensureFolder(para: .projects, components: ["引っ越し"])
        let home = try saveStore.ensureFolder(para: .areas, components: ["生活", "住まい"])
        let books = try saveStore.ensureFolder(para: .resources, components: ["読書"])
        _ = try saveStore.ensureFolder(para: .resources, components: [MemoImporter.inboxTitle])
        let folders = JournalExtractor.candidateNodes(from: try saveStore.allNodes())
        check("AI に見せる一覧に受信箱を入れない",
              !JournalExtractor.folderList(folders).contains(MemoImporter.inboxTitle))
        check("AI に見せる一覧はコードとパス",
              JournalExtractor.folderList(folders).contains("\(movingFolder.code)\t/Projects/引っ越し"))

        let picked = JournalExtractor.destinations(
            candidates: [(movingFolder.code, "10 月末に退去"), ("9999", "存在しない"),
                         (movingFolder.code, "重複"), (home.code, "住まいの話")],
            newPara: "", newPath: "", newReason: "", folders: folders)
        check("存在しないコードと重複を捨てる", picked.map { $0.nodeCode }.joined(separator: ","),
              "\(movingFolder.code),\(home.code)")
        check("PARA はフォルダ側から取る", picked.map { $0.para.rawValue }.joined(separator: ","),
              "projects,areas")

        let prefixed = JournalExtractor.destinations(
            candidates: [], newPara: "areas", newPath: "/Areas/健康/睡眠", newReason: "新しい話題",
            folders: folders)
        check("新しいパスから頭の / と PARA 名を落とす", prefixed.first?.newPath ?? "", "健康/睡眠")
        check("新しいパスの表示", prefixed.first?.displayPath ?? "", "/Areas/健康/睡眠")
        let otherPara = JournalExtractor.destinations(
            candidates: [], newPara: "areas", newPath: "Resources/料理", newReason: "",
            folders: folders)
        check("パスの頭の PARA 名を優先する", otherPara.first?.para.rawValue ?? "", "resources")
        let existingPath = JournalExtractor.destinations(
            candidates: [], newPara: "resources", newPath: "読書", newReason: "",
            folders: folders)
        check("新しいパスが既存と同じなら既存を使う", existingPath.first?.nodeCode ?? "", books.code)
        check("深さは 3 まで",
              JournalExtractor.normalizedNewPath("a/b/c/d", para: .areas)?.1 ?? "", "a/b/c")
        check("PARA 名だけのパスは提案にしない",
              JournalExtractor.normalizedNewPath("/Areas/", para: .areas) == nil)

        let moveDraft = JournalDraft(title: "t", body: "b", layer: .journal, nodeCode: "",
                                     para: .resources, suggestedPath: "x", destinations: picked)
        let applied = moveDraft.applying(picked[1])
        check("候補を選ぶと PARA・コードが揃う",
              "\(applied.para.rawValue) \(applied.nodeCode) [\(applied.suggestedPath)]",
              "areas \(home.code) []")
        let savedMove = try saveStore.commit(applied)
        check("選んだフォルダに保存される", savedMove.node.path, "/Areas/生活/住まい")

        check("返事: 候補の名前", JournalExtractor.resolveReply(
            "住まいの方で", destinations: picked, folders: folders)?.nodeCode ?? "", home.code)
        check("返事: 相づち＋名前は名前を優先", JournalExtractor.resolveReply(
            "はい、住まいで", destinations: picked, folders: folders)?.nodeCode ?? "", home.code)
        check("返事: 相づちだけなら第一候補", JournalExtractor.resolveReply(
            "はい", destinations: picked, folders: folders)?.nodeCode ?? "", movingFolder.code)
        check("返事: 候補外でもフォルダ名が合えばそこ", JournalExtractor.resolveReply(
            "読書に入れて", destinations: picked, folders: folders)?.nodeCode ?? "", books.code)
        check("返事: 分からなければ推測しない", JournalExtractor.resolveReply(
            "うーん、どうだろう", destinations: picked, folders: folders) == nil)
        check("返事: やめる", JournalExtractor.isCancelReply("やめておく"))

        let talk = [
            Message(id: "1", sessionID: "s", role: .user, content: "引っ越しの見積もり",
                    noteID: nil, createdAt: Date()),
            Message(id: "2", sessionID: "s", role: .assistant, content: "いつまでに？",
                    noteID: nil, createdAt: Date()),
        ]
        check("会話は 1 本のテキストにして渡す（最後が assistant でも prefill にしない）",
              JournalExtractor.transcript(of: talk), "ユーザー: 引っ越しの見積もり\n\nAI: いつまでに？")

        // --- 過去のジャーナルから引き出す: 道具（AI 呼び出し以外のすべて）---
        let recallStore = try Store.inMemory()
        let travelInsurance = try recallStore.ensureFolder(para: .areas, components: ["生活", "旅行", "保険"])
        let job = try recallStore.ensureFolder(para: .projects, components: ["転職"])
        try recallStore.createNote(in: travelInsurance, layer: .journal, title: "保険の比較",
                                   body: "クレカ付帯で足りるか迷った\n結局、家族旅行なので別に入った",
                                   occurredAt: Format.fileTimestamp.date(from: "202609191330")!)
        try recallStore.createNote(in: job, layer: .journal, title: "面談",
                                   body: "年収より裁量で決めたいと話した",
                                   occurredAt: Format.fileTimestamp.date(from: "202608021000")!)
        let removed = try recallStore.createNote(in: job, layer: .raw, title: "消したメモ",
                                                 body: "クレカ", occurredAt: Date())
        try recallStore.deleteNote(removed)
        let library = try recallStore.liveNotes()
        check("削除済みは探させない", library.count == 2, "\(library.count)")

        let insurancePath = "\(travelInsurance.path)/journal/\(travelInsurance.code)_202609191330.md"
        check("パスは Vault 書き出しと同じ形", JournalRecall.path(of: library[0]), insurancePath)

        check("glob: ** は何階層でも",
              JournalRecall.glob("/Areas/**/journal/*.md", in: library).hasPrefix(insurancePath))
        check("glob: ** は 0 階層にも一致", PathPattern("/Areas/**/保険/journal/*.md")!
            .matches(insurancePath))
        check("glob: * はフォルダをまたがない",
              !PathPattern("/Areas/*/journal/*.md")!.matches(insurancePath))
        check("glob: フォルダを指せばその下すべて",
              JournalRecall.glob("/Projects/転職", in: library).contains("面談"))
        check("glob: 日付で絞れる",
              JournalRecall.glob("**/*_202608*.md", in: library).contains("面談")
                && !JournalRecall.glob("**/*_202608*.md", in: library).contains("保険の比較"))
        check("glob: 日付と見出しを添える",
              JournalRecall.glob("/Areas/**", in: library), "\(insurancePath)\t2026-09-19\t保険の比較")
        check("glob: 無ければそう言う", JournalRecall.glob("/Resources/**", in: library), "一致する記録はありません")

        check("grep: 行番号つきで返す（見出しが 1 行目）",
              JournalRecall.grep("クレカ", scope: "", in: library), "\(insurancePath):2: クレカ付帯で足りるか迷った")
        check("grep: | で言い換えを並べられる",
              JournalRecall.grep("裁量|家族", scope: "", in: library).split(separator: "\n").count == 2)
        check("grep: 範囲で絞れる",
              JournalRecall.grep("裁量|家族", scope: "/Projects/**", in: library).split(separator: "\n").count == 1)
        check("grep: 正規表現として壊れていても文字どおり探す",
              JournalRecall.grep("(面談", scope: "", in: library), "一致する行はありません")

        let opened = JournalRecall.read(insurancePath, in: library) ?? ""
        check("read: 本文を返す", opened.contains("結局、家族旅行なので別に入った"))
        check("read: 日付と層を添える", opened.contains("date: 202609191330") && opened.contains("layer: journal"))
        let missing = JournalRecall.run(tool: "read", input: Data(#"{"path": "/Areas/無い.md"}"#.utf8),
                                        entries: library)
        check("read: 無いパスはエラーとして AI に返す", missing.isError)
        check("未知の道具はエラー", JournalRecall.run(tool: "rm", input: Data("{}".utf8), entries: library).isError)
        check("道具は 3 つ（Haiku でも 1 つに強制されない）", JournalRecall.tools.count == 3)
        check("道具のスキーマが読める", (try? JournalRecall.tools.map { try $0.payload() })?.count == 3)

        // --- 過去のジャーナルから引き出す: 検索意図の読み取り（AI 呼び出し以外のすべて）---
        let recallFolders = JournalExtractor.candidateNodes(from: try recallStore.allNodes())
        let intentSystem = RecallIntentReader.system(
            folders: recallFolders, today: Format.fileTimestamp.date(from: "202609271200")!)
        check("意図の読み取りにフォルダを載せる", intentSystem.contains("\(job.code)\t/Projects/転職"))
        check("意図の読み取りに今日の日付を載せる", intentSystem.contains("2026-09-27"))
        check("読ませるのはいまの発言だけ",
              RecallIntentReader.prompt(for: "転職どうしよう"), "# ユーザーのいまの発言\n転職どうしよう")

        let intentOutput = Data("""
            {"needs_recall": true, "intent": "前に転職を考えたとき、何を決め手にしたか",
             "folder_codes": ["\(job.code)", "9999", "\(job.code)", "\(travelInsurance.code)", "2", "3"],
             "keywords": ["転職", " 面談 ", "", "転職", "裁量", "a", "b", "c", "d", "e", "f"],
             "since": "2026-08-01", "until": "来月"}
            """.utf8)
        let intent = try RecallIntentReader.decode(intentOutput, folders: recallFolders)
        check("意図: 一覧に無いフォルダと重複を捨てる", intent.folderCodes.joined(separator: ","),
              "\(job.code),\(travelInsurance.code)")
        check("意図: 言葉の空白・空・重複を落とし 8 つまで",
              intent.keywords.joined(separator: ","), "転職,面談,裁量,a,b,c,d,e")
        check("意図: 日付の形でなければ空", intent.since == "2026-08-01" && intent.until.isEmpty)

        // 検索の前の絞り込み（期間）
        check("期間の指定が無ければ全期間", RecallIntent(
            needsRecall: true, intent: "", folderCodes: [], keywords: [], since: "", until: "")
            .scope(library).count == 2)
        let lastMonthOnly = RecallIntent(needsRecall: true, intent: "", folderCodes: [], keywords: [],
                                         since: "2026-08-01", until: "2026-08-31")
        check("期間の外は道具から見えない",
              JournalRecall.glob("/**", in: lastMonthOnly.scope(library)).contains("面談")
                && !JournalRecall.grep("クレカ", scope: "", in: lastMonthOnly.scope(library)).contains("クレカ"))
        check("期間の両端を含む", RecallIntent(needsRecall: true, intent: "", folderCodes: [], keywords: [],
                                          since: "2026-09-19", until: "2026-09-19").scope(library).count == 1)
        check("始まりだけの指定", RecallIntent(needsRecall: true, intent: "", folderCodes: [], keywords: [],
                                         since: "2026-09-01", until: "").scope(library).count == 1)
        check("期間外のパスは read もできない",
              JournalRecall.run(tool: "read", input: Data(#"{"path": "\#(insurancePath)"}"#.utf8),
                                entries: lastMonthOnly.scope(library)).isError)

        // 期間内で空振りしたら全期間に広げる（読み違えて絞りすぎても取りこぼさない）
        let widenedGrep = JournalRecall.run(tool: "grep", input: Data(#"{"pattern": "クレカ", "path": ""}"#.utf8),
                                            entries: library, intent: lastMonthOnly)
        check("期間内に無ければ全期間から返す",
              widenedGrep.text.hasPrefix("（2026-08-01 〜 2026-08-31 には無かったので、全期間から探しました）")
                && widenedGrep.text.contains("クレカ付帯"))
        let scopedGrep = JournalRecall.run(tool: "grep", input: Data(#"{"pattern": "裁量", "path": ""}"#.utf8),
                                           entries: library, intent: lastMonthOnly)
        check("期間内にあれば広げない", !scopedGrep.text.contains("全期間") && scopedGrep.text.contains("裁量"))
        let widenedRead = JournalRecall.run(tool: "read", input: Data(#"{"path": "\#(insurancePath)"}"#.utf8),
                                            entries: library, intent: lastMonthOnly)
        check("read も期間外なら全期間から読む", !widenedRead.isError && widenedRead.text.contains("家族旅行"))
        check("全期間にも無ければそのまま空振り",
              JournalRecall.run(tool: "grep", input: Data(#"{"pattern": "存在しない", "path": ""}"#.utf8),
                                entries: library, intent: lastMonthOnly).text == JournalRecall.noLines)

        let brief = RecallIntentReader.briefing(intent, folders: recallFolders)
        check("手がかりは本人の発言ではないと明記", brief.contains("本人の発言ではありません"))
        check("手がかりにフォルダのパスを添える", brief.contains("\(job.code) /Projects/転職"))
        check("手がかりの言葉は | で並べる", brief.contains("転職 | 面談 | 裁量"))
        check("手がかりの期間", brief.contains("2026-08-01 〜 …（発言から読み取った期間。"))

        let briefed = ClaudeClient.messages(
            [ClaudeClient.Turn(role: "assistant", text: "どうしたの？"),
             ClaudeClient.Turn(role: "user", text: "転職どうしよう")], briefing: brief)
        let briefedBlocks = briefed.last?["content"] as? [[String: Any]]
        check("手がかりは最後のユーザーの発言に別ブロックで添える",
              briefedBlocks?.count == 2 && briefedBlocks?.first?["text"] as? String == "転職どうしよう")
        check("それより前の発言は変えない（キャッシュが効く）", briefed.first?["content"] as? String == "どうしたの？")
        check("手がかりが無ければ文字列のまま",
              ClaudeClient.messages([ClaudeClient.Turn(role: "user", text: "x")], briefing: nil)
                .first?["content"] is String)

        // --- ふつうのジャーナル: ルートがそのまま置き場 ---
        let journalStore = try Store.inMemory()
        let journalRoot = journalStore.root(for: .journal)!
        let journalFolders = JournalExtractor.candidateNodes(from: try journalStore.allNodes())
        check("Journal のルートは保存先の候補に入る", journalFolders.map(\.code) == ["1"],
              journalFolders.map(\.code).joined(separator: ","))
        let fallback = JournalExtractor.destinations(candidates: [], newPara: "", newPath: "",
                                                     newReason: "", folders: journalFolders)
        check("候補が無ければ空（受け皿は呼び出し側）", fallback.isEmpty)
        check("Journal の受け皿はルート", SaveDestination(para: .journal, newPath: "", reason: "").displayPath,
              "/Journal")
        let plain = try journalStore.commit(JournalDraft(
            title: "なんでもない日", body: "散歩した", layer: .journal, nodeCode: "",
            para: .journal, suggestedPath: "", occurredAt: when))
        check("Journal はルート直下に保存", plain.node.id == journalRoot.id)
        check("Journal のファイル名は 1 始まり", plain.note.filename, "1_202609191330.md")
        let journalChild = try journalStore.createFolder(under: journalRoot, title: "朝")
        check("Journal の下のフォルダ", journalChild.code, "11")

        // --- v3 → v4: 旧番号（Projects 0 / Areas 1 / ...）からの移行 ---
        let legacyPath = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        do {
            let legacy = try Store(db: SQLiteDatabase(path: legacyPath))
            let legacyAreas = legacy.root(for: .areas)!
            let legacyLife = try legacy.createFolder(under: legacyAreas, title: "生活", seg: 1)
            let legacyTravel = try legacy.createFolder(under: legacyLife, title: "旅行", seg: 5)
            let legacyInsurance = try legacy.createFolder(under: legacyTravel, title: "保険", seg: 2)
            try legacy.createNote(in: legacyInsurance, layer: .journal, title: "保険", body: "比較",
                                  occurredAt: when)
            _ = try legacy.createFolder(under: legacy.root(for: .projects)!, title: "引っ越し")
        }
        do {
            // v4 の中身を v3 の形に戻す（Journal のルートが無く、先頭桁が 2 小さい）。
            let db = try SQLiteDatabase(path: legacyPath)
            try db.execute("DELETE FROM nodes WHERE para = 'journal'")
            try db.execute("UPDATE nodes SET code = CAST(CAST(substr(code, 1, 1) AS INTEGER) - 2 AS TEXT) || substr(code, 2)")
            try db.execute("UPDATE nodes SET seg = seg - 2, sort_order = sort_order - 1 WHERE parent_id IS NULL")
            try db.execute("UPDATE notes SET filename = CAST(CAST(substr(filename, 1, 1) AS INTEGER) - 2 AS TEXT) || substr(filename, 2)")
            try db.execute("PRAGMA user_version = 3")
            check("旧番号を再現", try db.query("SELECT code FROM nodes WHERE title = '保険'") { $0.string(0) }.first ?? "",
                  "1152")
        }
        let migrated = try Store(db: SQLiteDatabase(path: legacyPath))
        check("移行: ルートが 5 件で Journal が先頭",
              migrated.roots.map(\.code).joined(separator: ","), "1,2,3,4,5")
        check("移行: Areas の子孫のコード", try migrated.allNodes().first { $0.title == "保険" }?.code ?? "", "3152")
        check("移行: Projects の子のコード", try migrated.allNodes().first { $0.title == "引っ越し" }?.code ?? "", "21")
        check("移行: ファイル名", try migrated.notes(on: when).first?.note.filename ?? "", "3152_202609191330.md")
        check("移行: 新しいフォルダも新番号", try migrated.createFolder(under: migrated.root(for: .areas)!, title: "健康").code,
              "32")
        try? FileManager.default.removeItem(atPath: legacyPath)

        let marked = ClaudeClient.markingCacheBreakpoint([
            ["role": "user", "content": "こんにちは"],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "…"]]],
        ])
        let lastBlocks = marked.last?["content"] as? [[String: Any]]
        check("キャッシュの区切りは最後のブロックだけ",
              lastBlocks?.last?["cache_control"] != nil && marked.first?["content"] is String)

        print("")
        print(failures == 0 ? "すべて通過" : "\(failures) 件が失敗")
        if failures > 0 { exit(1) }
    }
}
