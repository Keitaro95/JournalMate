# JournalMate 開発設計書

最終更新: 2026-09-26

AI との対話がそのまま日々のジャーナルになり、PARA × メダリオンアーキテクチャで
自動的に整理されていく iOS アプリ。

---

## 1. コンセプト

| | |
|---|---|
| 入力 | AI とのチャット（Pro） / 直接メモ（無料） |
| 蓄積 | PARA 4分類 × 階層ディレクトリ × メダリオン3層 |
| 出力 | カレンダー（時間軸）/ ディレクトリツリー（意味軸） |

「分類のために手を動かす」のをやめ、**話す → 勝手に整理される** を実現する。

---

## 2. ストレージ方式の結論（最重要論点）

### 2.1 問い

> md ファイルで残すのか、スマホアプリでデータを圧迫しないメモ管理方法は？

### 2.2 結論

**SQLite 単一ファイルを正（source of truth）とし、本文は Markdown テキストで持つ。
ディレクトリ構造は「仮想」。実 .md ファイルは書き出し（エクスポート）時にだけ生成する。**

```
正:  JournalMate.sqlite  （1ファイル）
     └ notes.body に Markdown 文字列
副:  Attachments/        （画像等の実ファイルのみ）
出力: Vault.zip          （要求時に実 .md へ展開／Obsidian 互換）
```

### 2.3 なぜ「実 .md ファイル群」を正にしないのか

サイズは問題ではない。**テキストは圧倒的に軽い。**

| 想定 | 概算 |
|---|---|
| ジャーナル 1件 | 約 1.5 KB |
| 1日5件 × 10年 = 18,250件 | 約 27 MB |
| ＋ FTS5 全文索引（約1.5倍） | 約 **40 MB** |

10年分でも写真 15枚分。**容量を圧迫するのはテキストではなく画像**である。
それでも実ファイル方式を採らない理由は、容量ではなく以下の4点。

1. **検索が O(n) のディスク I/O になる**
   全文検索のたびに全ファイルを open/read する。1万件を超えると体感で破綻する。
   SQLite + FTS5 なら 1万件でも数ミリ秒。AI に文脈を渡す RAG 的な検索が前提なので、
   ここが致命的。

2. **小ファイル数千個は iOS と相性が悪い**
   APFS のブロック確保・inode オーバーヘッドに加え、iCloud バックアップが
   ファイル単位で走るため同期が重く、コンフリクトも起きやすい。

3. **再分類が壊れる**
   PARA とメダリオンの本質は「**後から分類を変えられる**」こと（非破壊型）。
   実ファイル方式だと再分類＝ファイル移動＝パス変更＝リンク切れ。
   DB なら `UPDATE nodes SET parent_id = ?` の 1 クエリで終わり、
   本文（Bronze / raw）は一切書き換わらない。

4. **トランザクションがない**
   「チャットからジャーナルを生成し、ノードを作り、索引を更新する」を
   アトミックに行えない。途中でアプリが落ちると壊れたデータが残る。

### 2.4 それでも Markdown を捨てない

- 本文カラムの中身は**素の Markdown 文字列**。DB 固有のリッチテキストにはしない。
- 設定画面から **Vault エクスポート**（YAML frontmatter 付き実 .md ＋実フォルダ階層）。
  Obsidian にそのまま放り込める。ロックインしない。
- つまり **「Markdown を値として持ち、ファイルシステムを持たない」**。

### 2.5 容量を圧迫しないための実装ルール

| 対象 | ルール |
|---|---|
| テキスト | そのまま DB。圧縮不要（誤差） |
| 画像 | DB に入れない。長辺 2048px / HEIC 品質 0.7 にダウンサンプルして `Attachments/` に保存、DB はパスのみ |
| 削除 | `deleted_at` によるソフト削除 → 30日後に実削除＋`VACUUM` |
| チャット履歴 | 生ログは 90 日で破棄。抽出済みジャーナルは永続（生ログは中間生成物） |
| FTS | FTS5 を `content='notes'`（external content）にして本文の二重保存を回避。トークナイザは `trigram`（既定の `unicode61` は CJK の連続を 1 トークンにまとめるため日本語が検索できない） |

### 2.6 採用技術

**libsqlite3 の薄い Swift ラッパを自前実装**（外部依存ゼロ）。

- SwiftData: 全文検索（FTS5）が使えない。ノートアプリでは致命的 → 不採用
- GRDB / SQLite.swift: 良いが SPM 依存が増える。必要なのは 200 行程度 → 自前

---

## 3. ディレクトリ構造の設計

### 3.1 三層の重ね合わせ

```
[第1層] PARA          … 自分との関わり度合いで分ける
[第2層] 任意の階層     … 生活 / 旅行 / 恋愛 …（ユーザーが作る）
[第3層] メダリオン     … /raw, /knowledge, /journal
```

```
Areas/                         ← PARA (3xx)
└ 生活/                        ← seg 1  → code 31
   └ 旅行/                     ← seg 5  → code 315
      └ 保険/                  ← seg 2  → code 3152
         ├ raw/       3152_海外旅行保険の比較.md
         ├ knowledge/ 3152_クレカ付帯だけで足りる条件.md
         └ journal/   3152_202609191330.md
```

### 3.2 番号体系

**コードは階層パスから導出し、ファイル名／フォルダ名の先頭に付与する。**
実体はあくまで階層構造。コードは AI と grep のための検索キー。

PARA 先頭桁:

| PARA | 先頭桁 | 範囲 |
|---|---|---|
| Journal（ふつうのジャーナル。PARA に振り分けない日々の記録。ルート直下に保存できる） | `1` | 100番台 |
| Projects（短期企画） | `2` | 200番台 |
| Areas（継続的な責任領域） | `3` | 300番台 |
| Resources（興味・学習） | `4` | 400番台 |
| Archives（終了・保管） | `5` | 500番台 |

v3 以前は Journal が無く Projects 0 / Areas 1 / Resources 2 / Archives 3 だった。
スキーマ v4 の移行でコードとファイル名の先頭桁を +2 して、Journal のルートを足す。

```
3      1      5      2
│      │      │      └ 保険   （第3階層 seg=2）
│      │      └─────── 旅行   （第2階層 seg=5）
│      └────────────── 生活   （第1階層 seg=1）
└───────────────────── Areas  （PARA 層）
```

- `code` は各階層の `seg` を連結した文字列（`3152`）
- DB には**マテリアライズ済み**で保持 → 前方一致 `code LIKE '115%'` で
  「旅行配下すべて」を一撃で取れる（AI への文脈投入に効く）
- 親を付け替えると子孫の `code` / `path` を再計算（再帰 CTE で一括 UPDATE）

### 3.3 メダリオン（Bronze / Silver / Gold）

| 層 | ディレクトリ | 中身 | 書き換え |
|---|---|---|---|
| Bronze | `raw/` | 先見者・専門家の情報、リンク、ソース。**ユーザーへのベクトル** | 不可（原本） |
| Silver | `knowledge/` | `raw` と `journal` から導いた教訓・現実的な指針 | 可 |
| Gold | `journal/` | その日その時その時間の記録 | 追記のみ |

原本を書き換えないので、後から PARA の所属を変えても情報は損なわれない。

### 3.4 ファイル名規約

```
journal:    <code>_<yyyyMMddHHmm>.md     例) 3152_202609191330.md
raw:        <code>_<slug>.md              例) 3152_海外旅行保険の比較.md
knowledge:  <code>_<slug>.md
```

---

## 4. 画面構成

```
TabView
├ 💬 Chat      （メイン）AI 対話 → ジャーナル自動生成
├ 📅 Calendar  UICalendarView。日付選択 → その日のジャーナル一覧（PARA タグ付き）
│              └ 上部の絞り込み: PARA のタブ → その下の自作フォルダのチェック
└ 🗂 Tree      PARA → 任意階層 → メダリオン層 → .md
```

### 4.1 Chat（メイン画面）

- 対話は Pro。無料ではプレーンな「今の気持ちを書く」入力欄 → そのまま journal 化
- 会話の区切りで **ジャーナル抽出**（要約・保存先フォルダの候補）を実行。
  **無料でも月 20 回まで**使える（§5.1）。残り回数は入力欄の上に出す
- 使い切ると Paywall。AI の呼び先が無いときは自分の言葉のまま案にする（記録は止めない）
- 抽出結果は**チャットの中で保存先を確かめて**からコミット（AI に勝手に書かせない）。仕組みは §4.1.1

#### 4.1.1 会話 → フォルダへの振り分け

前提: オンボーディング（§4.4）で、本人が PARA ごとに「話題にしたい領域」を答え、そこからフォルダができている。
**保存先はこのフォルダの中から選ぶ**のが原則で、新しいフォルダは例外。

```
オンボーディング        本人の答え → PARA ごとのフォルダ（/Projects/引っ越し、/Areas/生活/住まい …）
      │
      ▼
① 対話          システムプロンプトにフォルダ一覧を毎回載せる（ChatViewModel.system(folders:)）
      │           どの領域の話か曖昧なら、流れの中で「締め切りがあるか・続く責任か・興味か」を確かめる
      ▼
② 記録ボタン    JournalExtractor が、前回保存より後の会話を読み、タイトル・本文・層と
      │           保存先の候補（既存フォルダのコード 1〜3 件＋理由）を返す。
      │           どれにも当てはまらないときだけ新しいパスを提案
      ▼
③ 候補の検証    アプリ側で AI の答えを実在する保存先に直す（JournalExtractor.destinations）
      ▼
④ 確認          チャットの中の吹き出し（SaveProposalCard）で「どのフォルダに保存しますか？」
      │           候補のボタン / 文字の返事 / 「別の場所を選ぶ・内容を直す…」（確認シート）/ 保存しない
      ▼
⑤ 保存          Store.commit。「/Projects/引っ越し/journal/ に保存しました」と出す
```

| 決めごと | 理由 |
|---|---|
| AI に見せるフォルダは `JournalExtractor.candidateNodes`（PARA ルートと受信箱配下を除く） | 受信箱は仮置き場。そこを保存先に選ばせない |
| 一覧は `コード \t /Areas/生活/住まい` の形。候補はコードで返させる | 名前の表記揺れで別のフォルダができるのを防ぐ |
| 一覧に無いコード・重複は捨てる | AI が作ったコードで、黙って受信箱に落ちるのを防ぐ |
| **PARA はフォルダ側から取る**（`JournalDraft.applying`） | AI の言う PARA とフォルダが食い違っても、見えている保存先を正とする。確認シートでも同じ |
| 新しいパスは頭の `/` と PARA 名を落とし、深さ 3 まで（`normalizedNewPath`）。既存と同じパスなら既存を使う | 一覧に PARA 名込みのパスを見せているので、AI がそれを真似ると `/Areas/Areas/…` ができる |
| 会話は 1 本の user メッセージ（`ユーザー: … / AI: …`）にまとめて渡す | 最後が assistant の turn だと prefill と解釈され、Opus 5 / Sonnet 5 は 400 を返す |
| 抽出の材料は**前回保存より後の会話だけ**（`unsavedMessages`）。保存時に最後のメッセージへ `note_id` を付ける | 1 日 1 セッションなので、同じ日の 2 回目で前の分を二重に書かない |
| 保存先を尋ねているあいだの返事は、会話ログにも AI にも渡さない。「保存しました」などの一言（`notice`）も同じ | 次の返答やジャーナル化の材料に混ぜない |
| 候補が 1 件も無いときは、チャットで尋ねずに確認シートを開く | 選べるものが無い問いを出さない |

**文字の返事の解き方**（`JournalExtractor.resolveReply`。AI は呼ばない。無料枠も減らない）

1. 候補の名前（パスの末尾）が入っていれば、その候補。複数合うときは長い名前を優先し、同じ長さで並べば決めない
2. 候補に無くても、フォルダの名前が入っていればそのフォルダ（「読書に入れて」）
3. 名前が無く「はい」「それで」などの相づちなら第一候補。名前を先に見るので「はい、住まいで」は住まい
4. 「やめる」「保存しない」なら保存しない
5. どれでもなければ**推測で保存せず**、候補を押すか確認シートで選ぶよう聞き返す

**限界（公開後の課題）**: 1 回の記録で作るジャーナルは 1 件だけ。同じ区切りで複数の話題
（引っ越しと読書など）を話すと、どちらか 1 つのフォルダにまとめて入る。話題ごとに分けるには
抽出で複数件を返させ、確認の吹き出しを件数ぶん出す作りになる。

### 4.2 Calendar

- `UICalendarView` を `UIViewRepresentable` でラップ（SwiftUI の `DatePicker` は使わない）
- `UICalendarViewDecoration` でジャーナルのある日に PARA 色のドット
- `UICalendarSelectionSingleDate` で日付選択 → 下部に当日のノート一覧

**絞り込み（カレンダーの上のセクション）**

全部を一度に出すと、月末には色の違うドットが毎日並んで「その月に何をしていたか」が
読めなくなる。見る範囲を先に決めてから月を眺められるように、2 段の絞り込みを上に置く。

```
[ すべて | Projects | Areas | Resources | Archives ]   ← 横スクロールするタブ。下線が現在地
[ ☑ すべて  ☐ 引っ越し 01  ☐ 資格の勉強 02 ]          ← 選んだ PARA 直下の自作フォルダ
```

- 1 段目は PARA のタブ（`ParaTabBar`）。**左端の「すべて」が既定**で、
  これまでどおり全 PARA を映す。選択中のタブはその PARA の色の下線で示す
- 2 段目は 1 段目で選んだ PARA の**直下フォルダのチェックボックス**。
  チェックが 0 個なら PARA 全体、1 個以上ならその**部分木の和集合**だけを映す。
  番号（`code`）もチップに出して、ファイル名の接頭辞と結び付ける
- チェックは PARA ごとに覚える。タブを行き来しても消えない
- 絞り込みは `code` の前方一致で効かせる（§3.2）。フォルダを 1 つ選べば孫まで入る。
  ドットの集計と当日の一覧は**必ず同じ条件**で引く
  — 「ドットがある日を開いたら空だった」を起こさないため
- Tree でフォルダを作って戻ってきたら追従する。消えたフォルダのチェックは落とす
  （残すと、何も出ない絞り込みが手元に残ってしまう）

### 4.3 Tree

- ルート = PARA 4つ。掘ると任意階層 → `raw/knowledge/journal` → .md
- 各行に `code` を表示。最下層で Markdown 表示／編集

### 4.4 Onboarding（初回起動）

説明 → 体験 → プラン選択の 3 段。**価値を体験してから課金の話をする**。

1. **説明スライド 5 枚**: ようこそ / AI との対話（チャットのモック）/ 自動で整理・保存（保存先の提案のモック）/
   PARA のディレクトリ / カレンダー。モックは実物の部品にサンプルデータを入れて描く（画像は使わない）
2. **「試しにジャーナリングしてみましょう」**: 本物の AI と話して、その日のジャーナルを 1 本保存する
   - 入った時点で初期フォルダ（Areas/Work・Areas/Life・Resources/About Me）を作る。保存先の候補にするため
   - 対話は `ProFeature.onboardingChat`（最初の 1 通にだけ返事をする・Haiku の無料枠）で呼ぶ。ゲートウェイ側は `FREE_FEATURES`。
     端末に 1 本しかない DeviceCheck のビットには乗せない（`DEVICE_UNBOUND_FREE_FEATURES`）。乗せると抽出と枠を奪い合う
   - 2 通目以降は AI を呼ばず、「ジャーナルにする」へ促す一言を出す
   - AI が使えない（同意しない・枠切れ・通信失敗）ときも止めない。書いたものをそのまま保存できる。Paywall は出さない
3. **プラン選択**: 無料（7 日間無料トライアル）/ Pro 月・年 / Max 月・年。課金が未設定なら無料だけ

### 4.5 外部メモの取り込み（設定 > 外部からメモを登録）

すでに他所に溜まっているメモを一括で入れる経路。`VaultExporter` の逆。

**前段（ユーザーの手元）** — メモ.app には一括書き出しが無いので、
ショートカット.app で .txt 群に落としてもらう。画面ではこの 5 アクションを図で示す。

| # | アクション | 設定 |
|---|---|---|
| 1 | メモを検索 | フォルダを 1 つ選ぶ |
| 2 | 繰り返す（各項目） | |
| 3 | 日付をフォーマット | 日付 = 〈繰り返し項目〉の **作成日** / カスタム形式 `yyyyMMddHHmm` |
| 4 | テキストを取得 | 〈繰り返し項目〉 |
| 5 | ファイルを保存 | `NotesExport/〈フォルダ名〉/〈フォーマット済み日付〉_〈名前〉.txt` |

**メモ作成日をどう運ぶかが、この機能の芯。**
書き出した .txt のファイル作成日は「**書き出した日**」になるので、
ファイルシステムの日付をそのまま `occurred_at` にすると全件が同じ日に積み上がり、
カレンダー画面が壊れる。元の作成日を運べる経路はファイル名（か frontmatter）しかない。
そのため優先順は固定で、代用したら画面で件数を警告する。

| 優先 | 出どころ | 元の作成日か |
|---|---|---|
| 1 | frontmatter の `occurred` | ○（自分が書き出した Vault の往復） |
| 2 | ファイル名の先頭の日付 | ○（`yyyyMMddHHmm` 他 8 形式） |
| 3 | ファイルの作成日 | × 書き出した日 |
| 4 | ファイルの更新日 | × 書き出した日 |
| 5 | 取り込んだ時刻 | × |

**後段（アプリ）** — `.fileImporter` でフォルダごと選び、`Core/MemoImporter.swift` が処理する。

- 置き場所は **Resources / 受信箱 / 〈元のフォルダ名〉**、層は **`raw`**（原本・未加工）。
  受信箱の名前は表示言語で付く（英語なら `Inbox`）。§4.9
- 1 行目を見出しにする（メモ.app のメモ名 ＝ 本文 1 行目）
- `source_url` に相対パスを入れ、二度目の取り込みは重複させない（削除済みは除外＝入れ直せる）
- frontmatter に `path` があれば受信箱を経由せず元の位置へ戻す（Vault の往復）
- **取り込み時点では AI を通さない。** まず全件を確実に入れ、分類は後から `move` で
  引き直す（`code` / `path` だけ引き直して本文は触らない）＝ §3 の非破壊方針に揃える

### 4.6 過去のジャーナルから引き出す（Chat の中・Pro）

受信箱の一括分類・週次/月次の振り返り・knowledge（教訓）の自動生成は **2026-09 に削除した**。
AI は「教訓をまとめて渡す」のではなく、**過去のジャーナルを文脈にして本人へ語りかける／
「この時どうしてたっけ」「どうしよう」を過去から引き出す**方向へ寄せる。受信箱のメモはツリー画面から 1 件ずつ動かす。

`AI/RecallIntent.swift`（検索意図の読み取り）→ `AI/JournalRecall.swift`（検索）の 2 段。
検索は**エージェント型（just-in-time）**にする。

```
① 検索意図の読み取り（構造化出力 1 回・read_search_intent）
   入力: いまの発言だけ ＋ 本人のフォルダ（PARA のコード \t パス）＋ 今日の日付（それまでの会話は読ませない）
   出力: needs_recall / 知りたいこと / フォルダ最大 3 / 探す言葉最大 8（言い換え込み）/ 期間
   → needs_recall が false なら道具を渡さずに普通に返す（ここで終わり）
   → 発言から期間が読めれば、道具に渡す記録をまずその期間だけに絞る。読めなければ全期間。
     決まった言い方はさせない（「最近」「この前」「今の案件で」のような普段の言葉と話の中身から読む）。
     期間内で空振りしたら、全期間でやり直して返す
② 検索しながら返答（ストリーミング＋道具）
   最後のユーザー発言に <search_intent> ブロックとして ① を添える
  → glob  /Areas/生活/**/journal/*.md      パスと日付と見出しだけ返す（軽い識別子）
  → grep  引っ越し|転居  範囲 /Areas/生活/**  一致した行だけ返す
  → read  /Areas/生活/住まい/journal/111_202609191330.md   要る 1 件だけ全文
  → 日付と中身を添えて語りかける
```

| 決めごと | 理由 |
|---|---|
| 検索の前に**意図を読み取る段**を置く | 本人は「どうしよう」「前にもあった気がする」としか言わない。言葉のまま grep すると空振りする。何を知りたいか・どのフォルダか・過去の自分が書きそうな言葉を先に決める |
| 意図は最後のユーザー発言に別ブロックで添え、システムプロンプトには混ぜない | システムプロンプトを毎回変えるとキャッシュが効かない。本人の発言と取り違えないよう「アプリが読み取ったもの」と明記する |
| **期間は検索の前に絞る**（`RecallIntent.scope`）。ヒントとして渡すのではなく、まず期間外の記録を道具から見えなくする | 「最近」の話に何年も前の記録を持ち出さない。AI が絞り忘れても外に出ない |
| 本人に決まった言い方をさせない。期間は普段の言葉から AI が読む | 「過去 3 か月」のような言い方を覚えさせるのは負担 |
| 期間内で空振りしたら全期間に広げる（`JournalRecall.run(tool:input:entries:intent:)`）。広げたことは結果の頭に書く | 期間は推測なので外れることがある。絞りすぎて「記録が無い」と言わせない |
| 意図の段が `needs_recall: false` なら道具を渡さない | 雑談のたびに往復させない。探すかどうかの判断をここに寄せる |
| 意図の段が形を守らなかったら、意図なしで返答を続ける | 返答そのものを止めない。そのときは返答側の AI が自分の判断で探す |
| 埋め込み・ベクトル索引を作らない。道具が呼ばれるたびに `Store.liveNotes()` を引く | 事前処理なし。書いた直後の記録もすぐ探せ、索引の作り直しや食い違いが起きない |
| パスは Vault 書き出しと同じ `<フォルダ>/<層>/<コード>_<日時>.md` | PARA の構造そのものが検索の手がかりになる。フォルダ一覧はもともとシステムプロンプトにある |
| 道具は glob / grep / read の 3 つだけ | プリミティブに絞り、組み立ては AI に任せる。3 つあるのでゲートウェイの `forceSingleTool` にも掛からない |
| 往復は 1 返答 5 回まで（`JournalRecall.maxRounds`）。超えたら `tool_choice: none` で答えさせる | 原価を青天井にしない |
| 往復のたびに 1 日の上限を見て、近ければ打ち切る | ストリームは始まると止められないので、次の往復の手前で切る |
| 読んだ記録は会話ログに残さない（保存するのは返答の本文だけ） | 次の発言で全文を持ち回らない。要ればまた探す |
| システムプロンプトと最後のメッセージにキャッシュの区切り | 往復のたびに同じ前置きを読み直すので、キャッシュ読み出しで安くする |
| 見つからなければそう言わせる。記録に無いことを「書いていた」と言わせない | 本人の過去を捏造しない |
| オンボーディングの体験（`.onboardingChat`）には道具を渡さない | まだ記録が無い。Haiku の無料枠を往復で使わせない |

### 4.9 言語（日本語 / 英語）

Apple 推奨の方法に揃える。**アプリ内に言語の切り替え画面は作らず、iOS の設定アプリの
「言語」に任せる**（アプリが 2 言語以上に対応していると、設定アプリのアプリのページに
自動で出る）。`@AppStorage` や `AppleLanguages` の書き換えは使わない。

| 決めごと | 中身 |
|---|---|
| 開発言語 | **English**（`developmentRegion = en`）。対応言語は en / ja |
| 翻訳ファイル | `Resources/Localizable.xcstrings`（String Catalog）。日本語は ja 列に入っている |
| キー | **コードに書いた英語の文章そのもの**（自然文キー）。英語は訳を持たず、キーがそのまま出る |
| 日本語の文言 | 対応前の日本語をそのまま ja 列に移した。日本語での見た目は変わっていない |
| 設定画面 | 「言語」の行を置き、タップで設定アプリのこのアプリのページを開く。今の言語を、その言語自身の表記（日本語 / English）で右に出す |

**書き方の決まり**

- `Text("...")` などに**文字列リテラルを直接**渡すと翻訳対象になる。
  `"a" + "b"` の連結は `String` になって翻訳されないので、**1 つのリテラルにまとめる**
  （長いものは `"""` と行末の `\` で折り返す）
- モデルやエラーなど、`String` で持つ文言は `String(localized: "...")` で作る
  （`Para.subtitle`、`Layer.summary`、`ProFeature.title`、各 `errorDescription` など）
- 件数は `Text("^[\(n) item](inflect: true)")`。英語は 1 item / 3 items が自動で切り替わり、
  日本語は「%lld 件」
- 同じ英語で日本語が違うものはキーを分ける（例: API キーの「保存」は `Save Key`、
  ジャーナル確認の「記録」は `Save`）
- 書式だけの文字列（`%lld`、`sk-ant-...`、`JournalMate`、`PARA`、`Pro` など）は
  カタログで「翻訳しない」にしてある
- `#if canImport(RevenueCat)` の中の文言は、SDK を足すまでビルドされず自動抽出されないので、
  カタログに手動キーとして入れてある

**言語に合わせないもの**

| 対象 | 扱い | 理由 |
|---|---|---|
| タブ名（Chat / Calendar / Tree） | どちらの言語でも英語 | 画面の固有名として文中でも「Tree 画面」と呼んでいる。`"Chat" as String` で渡して翻訳対象から外している |
| PARA 名・層の名前（Projects / raw など） | どちらの言語でも英語 | パスとファイル名の一部。データなので訳さない |
| AI へのシステムプロンプト | 日本語のまま | 代わりに `ClaudeClient.languageInstruction` を全呼び出しに足し、「ユーザーが書いている言語で出力する。判断がつかなければアプリの表示言語」と指示する |

**受信箱の名前** — フォルダ名は DB に保存されるので、表示言語で名前を変えると、
言語を切り替えたときに受信箱が 2 つできてしまう。

- 新しく作るときは表示言語の名前（`MemoImporter.inboxTitle` = 「受信箱」/ `Inbox`）
- 探すときは**どちらの名前でも**受信箱とみなす（`MemoImporter.inboxTitles`）
- 既にあるなら、その名前を使い続ける（`Store.inboxTitle(in:)`）

**確認のしかた**

- 早いのは Xcode の **Product → Scheme → Edit Scheme → Run → Options → App Language**
  （コマンドラインなら起動引数 `-AppleLanguages "(en)"`。§10.3）
- 設定アプリ経由で確かめるときは、端末の **設定 → 一般 → 言語と地域** で
  日本語と英語の両方を「優先する言語」に入れておく。1 言語だけだと、
  iOS のバージョンによってはアプリのページに「言語」が出ない
- 言語を変えると iOS がアプリを終了させ、次に開いたときに新しい言語で出る

---

## 5. 課金

### プラン構成（まとめ・2026-09-26 時点）

プランは **無料 → トライアル → Pro → Max** の 4 段。
トライアルは App Store を通さないアプリ内の独立したプランで、Pro と Max は最初から課金して買う。
ほかに、自分の Claude API キーを入れる **BYO キー**の逃げ道がある（§5.3）。

| | 無料 | トライアル | Pro | Max |
|---|---|---|---|---|
| 料金（税込） | ¥0 | ¥0 | 月額 **¥770** / 年額 **¥7,700** | 月額 **¥2,980** / 年額 **¥29,800** |
| 期間 | ずっと | **7 日**（1 端末 1 回・自動課金なし） | 自動更新 | 自動更新 |
| 始め方 | トライアルが終わる（か使えない端末） | 初回起動のプラン選択か Paywall | App Store で購入 | App Store で購入（Pro からは即時アップグレード） |
| モデル | Haiku 4.5 | Haiku 4.5 | Sonnet 5 | Opus 5 |
| 書くこと・AI | **×（閲覧と書き出しだけ）** | **全部** | **全部** | **全部** |
| 1 日の上限（重み付き） | — | 8 万 | 8 万 | 16 万 |
| 期間 / 月の上限 | — | 7 日間の合計 40 万 | 月 60 万 | 月 120 万 |
| 1 人の原価（上限まで使った最悪値） | 0（初回起動の体験 2 回ぶんだけ） | 約 ¥60（$0.40） | ¥178 / 月 | ¥888 / 月 |
| 手取りに残る割合（月額・手数料 15%） | — | — | **70%** | **61%** |

- **2026-09-28 に変更: トライアル後の無料プランは閲覧と書き出しだけ**。ジャーナルを書く（手入力・フォルダの Add / Edit）、
  AI との対話・ジャーナル抽出は、触った瞬間に Paywall（`ProGate`・`ProFeature.journalWrite`）。
  無料の AI 呼び出しは初回起動の体験（`onboarding_chat` / `onboarding_extract` 各 1 回）だけ。以下の §5.1 の表は旧方針
- **AI の機能** ＝ 対話・ジャーナル抽出・過去のジャーナルから引き出す
- 上限は価格から逆算している（$1 = ¥148）。Pro は手取りの 30%、Max は 40% を原価に充てる（§5.6）
- 年額はどちらも月額の 10 か月分。年額の人は 1 か月あたりの手取りが少ないので、残る割合は
  Pro 64%・Max 54% に下がる（§5.7）
- トライアルの合計 14 万は、Pro の月の上限 60 万を 7 日に日割りした値（60 万 × 7/30）
- BYO キーの人は Sonnet 5 で全機能。自分の Anthropic アカウントに請求が行くので上限は掛けない

**主キーは端末 ID（すべて統一）** — 仕組みの全体は §5.9

契約・使用量・無料枠・トライアルは、**すべて同じ端末 ID** で数える。RevenueCat の appUserID も同じ値。

| 決めごと | 中身 |
|---|---|
| 端末 ID | アプリが初回に作る UUID（`DeviceIdentity.id`）。Keychain の**この端末限定**（`ThisDeviceOnly`）に置く |
| アプリを入れ直すと | **変わらない**（Keychain は削除後も残る）→ 使用量・無料枠・トライアルは続きから。契約も同じ ID のまま |
| 別の端末では | **別の ID**（iCloud キーチェーンやバックアップで移らない） |
| 端末を初期化すると | 消える → 台帳は白紙になるが、DeviceCheck のビット（Apple 側）が無料枠とトライアルのやり直しを止める |
| ゲートウェイでの使い方 | セッション JWT の `sub` ＝ 端末 ID。台帳は `<端末 ID>`（契約）/ `free:<端末 ID>` / `trial:<端末 ID>`、購読キャッシュは `sub:<端末 ID>` |
| App Attest の keyId | **本物のアプリかの確認にだけ**使う。入れ直すと作り直され、新しい鍵が同じ端末 ID に結びつく |

なぜ端末 ID にそろえたか — 以前は契約を RevenueCat の匿名 ID、無料枠とトライアルを App Attest の keyId で
数えていた。どちらも入れ直すと作り直されるので、**入れ直して購入を復元すると、契約者の月の上限が白紙に戻る**
（Max なら Opus の原価の上限が崩れる）抜け穴があった。主キーを 1 つにすれば、何をどこで数えているかが
食い違わない。

1 つの Apple ID で複数の端末を使う場合、RevenueCat の既定の復元動作（Transfer）では
**最後に「購入を復元」した端末が契約を持つ**。契約は 1 端末ずつ、という扱いになる。

**どこで決まっているか**

| 決めごと | 正（強制する側） | 鏡（アプリの表示・事前停止） |
|---|---|---|
| どのプランか | RevenueCat のエンタイトルメント `pro` / `max`（appUserID ＝ 端末 ID）、トライアルはゲートウェイの台帳 `trial:<端末 ID>` | `Entitlement.paidPlan` / `trialEndsAt` |
| モデル | ゲートウェイが**上書き**（`PLANS` / `TRIAL` / `FREE_MODEL`）。アプリの指定は効かない | `ClaudeClient.model(for:)` / `trialModel` |
| 1 日の上限 | `Gateway/src/config.ts` の `PLANS` / `TRIAL` | `TokenBudget.daily(for:)` / `trialDaily` |
| 月・期間の上限 | 同上（トライアルは台帳の全期間の合計 `Limits.total`） | なし（429 を受けて文言にする） |
| 無料枠の回数 | `FREE_FEATURES`（端末 ID ごと ＋ DeviceCheck bit0） | `ProFeature.monthlyFreeLimit` |
| トライアルは 1 端末 1 回 | DeviceCheck bit1 | `Entitlement.canStartTrial` |

**RevenueCat / App Store Connect の構成**

| 商品 ID | 価格 | エンタイトルメント | Offering の package |
|---|---|---|---|
| `app.journalmate.pro.monthly` | ¥770 | `pro` | `$rc_monthly` |
| `app.journalmate.pro.annual` | ¥7,700 | `pro` | `$rc_annual` |
| `app.journalmate.max.monthly` | ¥2,980 | `pro` ＋ `max` | `max_monthly` |
| `app.journalmate.max.annual` | ¥29,800 | `pro` ＋ `max` | `max_annual` |

- 4 つとも**同じサブスクリプショングループ**に入れ、Max を上位ランクにする（Pro → Max は即時・差額は日割り）
- App Store の無料トライアル（導入オファー）は付けない。審査員には Pro / Max のオファーコードを渡す
- Max の商品は `pro` にも紐づけるので、「全機能が使えるか」は `pro`、Max かどうかは `max` だけを見る。
  アプリとゲートウェイはどちらも **`max` を先に見る**
- アプリは商品 ID に `.max.` を含むかで Pro / Max を見分ける（`BillingConfig.maxProductMarker`）

**上限に当たったとき・プランが変わるとき**

| 場面 | 応答 | アプリの動き |
|---|---|---|
| 無料枠 20 回を使い切った | 402 | Paywall（トライアル / Pro / Max が並ぶ） |
| Pro 専用の機能を無料で押した | 402 | 同上 |
| 1 日の上限（全プラン共通） | 429 `daily` | 「今日の上限」。翌日（UTC）に戻る。記録は続けられる |
| トライアルの 7 日間の合計 | 429 `total` | 「トライアルの枠を使い切った」。Pro / Max を案内 |
| トライアルの 7 日が過ぎた | — | 無料に戻る。請求なし |
| Pro / Max の月の上限 | 429 `monthly` | 「今月の上限」。来月に戻る。**Pro の人にだけ** Max を案内 |
| Pro → Max・新規購入 | Webhook → 聞き直し。届く前でもアプリの申告（`X-Plan`）で聞き直す | Paywall が閉じ、設定のプランが変わる |
| 解約・失効 | Webhook（失効系は即時） | 無料に戻る |

詳しい理由と数字: 何を課金するか §5.1 / 無料枠 §5.2 / 経路 §5.3 / 中継サーバと DeviceCheck §5.4 /
導入の段取り §5.5 / 上限 §5.6 / 価格と原価率 §5.7 / トライアル §5.8 / 端末の見分け方 §5.9

---

RevenueCat（`purchases-ios` 5.x）＋ サブスクリプション 2 段（Pro / Max）。
エンタイトルメントは `pro` と `max`。Max の商品は **`pro` と `max` の両方**に紐づけるので、
「Pro の機能が使えるか」は `pro` だけを見ればよく、Max かどうかは `max` を見る。

### 5.1 何を課金するか

**「記録」は課金しない。課金するのは「整理された状態」と「振り返り」。**
このアプリの価値はデータが溜まるほど上がるので、入力を絞ると
課金する理由の方が先に消える。

| 機能 | 無料 | Pro | 置き場所 |
|---|---|---|---|
| ジャーナルの手入力・カレンダー・ツリー・Vault 書き出し | ○ | ○ | — |
| 外部メモの取り込み（受信箱へ） | ○ | ○ | `MemoImporter` |
| **AI でのジャーナル抽出・PARA 自動推定** | **月 20 回** | 回数制限なし（利用量の上限は §5.6） | `ProFeature.journalExtract` |
| AI との対話 | × | ○ | `ProFeature.aiChat` |
| 過去のジャーナルから引き出す | × | ○ | `ProFeature.pastRecall` |

各機能をここに置いた理由:

| 機能 | なぜそこか |
|---|---|
| ジャーナル抽出に**無料枠を置く** | 「話す → 勝手に整理される」を一度も見せないまま壁を出すと、何を買うのか分からない。確認シートで PARA が当たっている絵を数回見てから壁に当たる |
| 対話に上限を置く | 原価が唯一青天井なのがここ。抽出は構造化された 1 回の呼び出しで終わるが、雑談は終わらない |
| **書き出しは無料のまま** | ジャーナルアプリでデータの出口を人質に取ると信頼が消える |
| オンボーディングの AI ツリー生成も無料のまま | 1 インストール 1 回だけなので原価が固定。ここを有料にすると活性化を殺す |

### 5.2 無料枠の数え方

`ProFeature` が機能を、`Usage.access(to:isPro:usedThisMonth:)` が解放判定を持つ。
消費数は `feature_usage(feature, period, count)` に暦月（`"2026-09"`）で積む。

| 決めごと | 理由 |
|---|---|
| **通信が成功したときだけ数える** | 失敗した呼び出しで無料枠を減らさない |
| 契約者のぶんは数えない（`FeatureAccess.pro`） | 数える意味がないし、DB も引かない |
| 残数を画面に出す（Chat の入力欄の上・設定） | 黙って減らさない |
| 判定は純粋関数に切り出す | `Verification` から呼べる。UI を動かさずに境界を確かめられる |
| **正はサーバ**。応答の `x-free-used` で上書きする | 入れ直してアプリの数えが 0 に戻っても、表示がサーバの数字に揃う |

#### 無料ユーザーはどうやって AI に届くか

未契約でキーも無い人は、**中継サーバ経由で無料枠ぶんだけ**呼べる（§5.4）。
トライアル中の人は無料枠ではなくトライアルの枠で呼ぶ（§5.8）。
アプリは `X-Feature` で機能を伝え、サーバが回数を数える。

| 決めごと | 理由 |
|---|---|
| 無料で開けるのは `journal_extract` だけ（`FREE_FEATURES`） | 対話は Pro のまま |
| 無料の呼び出しは**サーバがモデルを Haiku に固定**し、出力も 2,000 に絞る | 1 回あたりを安くしておくことが、無料枠を開けられる条件 |
| 無料枠**全体**の 1 日・1 か月の出費に天井（`FREE_POOL_*`） | 個人を縛りきれなくても、総額は決まる |
| **入れ直しで枠を戻させない**（DeviceCheck） | 下の §5.4 に詳細 |

### 5.3 全機能が開く 3 つの経路

```
Entitlement.isPro = isSubscribed || hasOwnKey
```

1. **サブスクリプション** — RevenueCat の `pro` エンタイトルメント（Max は `max` も）。
   原価はこちら持ちなので、AI の呼び先は自前のゲートウェイになる。
   Pro と Max の違いは**モデルと使える量だけ**で、使える機能は同じ（`PaidPlan`、§5.7）。
2. **BYO API キー** — ユーザー自身の Claude API キー（Keychain）。上級者向けの逃げ道として残す。
   キーを持っている人の母数は小さいので売上はほぼ食われない。

3. **無料トライアル** — 7 日間、全機能を Haiku で（§5.8）。

契約者が両方持っているときはゲートウェイを優先する（払った人に二重に原価を持たせない）。

### 5.4 鍵の置き場所と中継サーバ

| 鍵 | アプリに入れてよいか |
|---|---|
| RevenueCat の公開 SDK キー（`appl_...`） | ○ 公開前提の値 |
| **Anthropic の API キー** | **× 絶対に入れない** |

バイナリから抜けるし、抜かれた請求はこちらに来る。
そのため契約者の AI 呼び出しは中継サーバ（`Gateway/`）を通す。
実装は Cloudflare Workers、詳細は [Gateway/README.md](Gateway/README.md)。

```
アプリ ──POST /v1/messages──▶ Gateway ──▶ api.anthropic.com
                                │ ① 本物のアプリか      App Attest → JWT   … 401
                                │ ② 契約中か・プランは  RevenueCat         … 402
                                │ ③ 今日の上限内か      Durable Object     … 429
                                │ ④ 渡してよい body か  モデル・max_tokens … 400
```

**端末 ID（appUserID）は認証ではない。** ただの文字列なので詐称できる。
そのまま信じると、URL が 1 回漏れただけで誰でも使える無料の Claude プロキシになる。
そこで **App Attest**（本物のアプリのコピーからの呼び出しであることを Apple の鍵で保証）を
入口に置き、通ったら 24 時間の JWT を配る。

| 段 | アプリ側 | サーバ側 |
|---|---|---|
| チャレンジ | `GatewaySession` | `POST /v1/challenge`（使い捨て・5 分） |
| 初回 | `DCAppAttestService.attestKey` | attestation を検証し、端末の公開鍵を保存 |
| 2 回目以降 | `generateAssertion` | 署名とカウンタを検証（再生を防ぐ） |
| 入れ直した後 | Keychain に keyId だけ残り、鍵の本体は消えている → `invalidKey` で keyId を捨てて初回からやり直す | 新しい鍵を検証し、同じ端末 ID に結びつける |
| 以後 | `Authorization: Bearer <JWT>` | JWT を検証するだけ |

署名する平文は **「チャレンジ.端末 ID」**。両側で同じ組み立て方にする
（チャレンジだけだと、署名を別の端末 ID に使い回せる）。
さらに **keyId と端末 ID を初回で結びつけ**、以後は変えさせない。
App Attest が言えるのは「本物のアプリである」ことまでで「どの端末か」ではないので、
1 つの鍵で次々と別の端末 ID を名乗って枠を食い潰すのを、この結びつけで止める。

#### 無料枠を端末に縛る（DeviceCheck）

無料枠を開けると「アプリを入れ直して枠を作り直す」が成立してしまう。
入れ直しは端末 ID（Keychain に残る）で塞げるが、**端末を初期化すると端末 ID も消える**。
App Attest の keyId も `identifierForVendor` も同じく作り直される。

初期化まで含めて塞げるのは **DeviceCheck** だけ。端末ごとに 2 ビットと最終更新月を **Apple のサーバ**に
置く仕組みで、**アプリを削除しても残る**（Apple の用途説明にある
「プロモーション特典をすでに受け取った端末の識別」がそのままこれ）。

| 持てるもの | 使い方 |
|---|---|
| bit0 | この端末は無料枠を**開始した** |
| bit1 | この端末は無料トライアルを**使った**（一生に 1 回。月では戻らない。§5.8） |
| last_update_time（"2026-09"） | 最後にどちらかを書いた月。**月が変われば古くなる ＝ bit0 の月次リセットが自動** |

last_update_time は 2 ビットで共有なので、**片方を書くときにもう片方を壊さない**。
無料枠の印を付けるときは bit1 を読んでそのまま書き戻し、トライアルの印を付けるときは
bit0 を「今月のものなら残す・先月以前なら落とす」（残すと、書いた瞬間に先月の bit0 が
「今月開始済み」に化けて今月の無料枠を奪う）。`bitsForFreeMark` / `bitsForTrialMark`。

2 ビットしか無いので「20 回のうち何回」は持てない。そこは台帳（端末 ID ごと）で数え、
**組み合わせて**使う。

```
初回の無料呼び出し  → 台帳に行が無い → DeviceCheck を見る
                      ├ 今月開始済み → 402（初期化して作り直そうとした場合もここ）
                      └ 未開始       → 通す → 成功したら bit0 を立てて行を作る
2 回目以降          → 台帳に行がある → 端末は見ない（回数だけ数える）
```

入れ直しても端末 ID が同じなので、台帳の回数はそのまま続く。
初期化すると台帳の行は白紙になるが、ビットは残っているので今月ぶんは渡さない。
Apple 側が落ちているときは通す（共有プールの天井があるので、総額は守られる）。

`BillingConfig.gateway` が空のあいだは、AI は BYO キーを入れた人だけが使える v1 の挙動のまま。

### 5.5 導入の段取り

1. Xcode > File > Add Package Dependencies… に `https://github.com/RevenueCat/purchases-ios`
   （Up to Next Major 5.0.0）を足し、プロダクト `RevenueCat` をターゲットに追加
2. App Store Connect で 4 つのサブスクリプションを**同じサブスクリプショングループ**に作る（§5.7）。
   商品 ID は `app.journalmate.pro.monthly` / `.pro.annual` / `.max.monthly` / `.max.annual`
   （アプリは ID に `.max.` を含むかで Pro と Max を見分ける。`BillingConfig.maxProductMarker`）。
   グループ内のランクは **Max を上**にする（Pro → Max が即時のアップグレードになり、差額は日割り）。
   App Store の無料トライアル（導入オファー）は**どの商品にも付けない**（トライアルはアプリ内の別プラン。§5.8）
3. RevenueCat の Project settings で **Restore behavior を「Transfer to new App User ID」（既定）**のままにする
   （appUserID は端末 ID。機種変更して復元すると、契約が新しい端末に移る）。
   `pro` と `max` のエンタイトルメントを作る。Pro の 2 商品は `pro` に、
   Max の 2 商品は `pro` と `max` の両方に紐づける。`default` Offering に 4 つとも package で入れる
   （Pro は `$rc_monthly` / `$rc_annual`、Max は custom の `max_monthly` / `max_annual`）
4. `BillingConfig.revenueCatAPIKey` に公開キーを入れる
5. 中継サーバを立てる（[Gateway/README.md](Gateway/README.md) の手順）。
   KV の作成 → Apple のルート CA と秘密の投入 → `wrangler deploy` →
   `BillingConfig.gateway` にデプロイ先を入れる → RevenueCat の Webhook を向ける
6. Xcode の Signing & Capabilities に **App Attest**（`com.apple.developer.devicecheck.appattest-environment`）
   を足す。シミュレータでは動かないので、開発中は Gateway 側を `ATTEST_MODE = "off"` にし、
   Scheme の環境変数 `GATEWAY_DEV_BYPASS` に合言葉を入れる（DEBUG のシミュレータ実行でだけ読む。cloudflare.md §7）
7. 無料枠を端末に縛るなら、App Store Connect で DeviceCheck 用の鍵（.p8）を作り、
   Gateway に `DEVICECHECK_KEY_P8` / `DEVICECHECK_KEY_ID` / `APPLE_TEAM_ID` を入れる
   （入れないと、アプリを入れ直すたびに無料枠が戻る）

SDK を足すまでは `#if canImport(RevenueCat)` で `SubscriptionService` が丸ごと無効になり、
アプリは BYO キーだけの v1 として動く。Paywall は「課金はまだ設定されていません」と出す。

---

### 5.6 トークンの上限（1 日・1 か月）

無料枠（`ProFeature.monthlyFreeLimit`）は「**何回**使えるか」を決める。
これだけでは、1 回の会話を無限に続ける人を止められない。
原価を止めるにはもう 1 本、「**どれだけ**使えるか」の軸が要る。

| 軸 | 単位 | 期間 | 対象 | 置き場所 |
|---|---|---|---|---|
| 無料枠 | 呼び出し回数 | 暦月 | 無料ユーザー | `feature_usage` |
| **トークン上限** | 重み付きトークン | **1 日** | **契約者** | `token_usage` ＋ ゲートウェイ |

BYO キーの人は自分の Anthropic アカウントに請求が行くので上限を掛けない
（`Entitlement.isMetered` が false）。消費量の表示だけはする。

**重み付け** — 素のトークン数で数えると、長文を書かせる人だけが極端に得をする。
原価の比に合わせて出力を重くする（`TokenBudget`）。

```
weighted = input + output × 5 + cacheRead ÷ 10
```

**数字は推測しない。** Anthropic の応答の `usage` をそのまま読む
（ストリーミングは `message_start` で入力、`message_delta` で出力が確定する）。
`ClaudeClient.onUsage` が 1 呼び出しごとに吐き、`Store.record(_:)` が日ごとに積む。
**失敗した呼び出しでも記録する** — そこまでに生成されたぶんは実際に課金されているため
（無料枠の回数とは逆の扱いになる。回数は「使えたか」、トークンは「かかったか」を数える）。

**止め方** — ストリームは走り出すと途中で止められないので、
1 回ぶんの余白（`TokenBudget.headroom`）を残して**始める手前**で切る。
上限に当たっても記録そのものは止めない。

| 場面 | 上限に当たったとき |
|---|---|
| チャット送信 | 発言は保存し、AI の返答だけ止める（1 セッションに 1 度だけ知らせる） |
| 記録（抽出） | 自分の言葉のままジャーナル案にする。止めない |
| オンボーディング | AI 無しの経路に落ちる |

#### 正はサーバ、アプリは鏡

アプリ側の `token_usage` は**表示と事前停止のため**のもので、上限の根拠にはならない。
端末をまたげば合算できないし、DB を消せば戻る。
課金を止める判断はゲートウェイ側で持つ。

```
アプリの token_usage      … 残量表示・呼び出し前の自制。BYO キーでも動く
ゲートウェイの usage 台帳  … 402 / 429 を返す根拠。こちらが正
```

| 論点 | 決め |
|---|---|
| 保存先 | **Durable Object（ユーザー 1 人 1 個）**。KV は結果整合なので、同時リクエストで上限を越える。DO なら直列化されて数え落ちがない |
| 日の境界 | **UTC 固定**。端末のタイムゾーンで数えると、移動や設定変更で枠が復活する。アプリには `X-Budget-Reset`（epoch 秒）を返し、アプリは自分で日付を計算しない |
| 予約と精算 | 開始時に `max_tokens` ぶんを**仮押さえ**し、終了後に実測で差し戻す。ストリーム中に上限を越えるのを防ぐ |
| 超過時 | `429` ＋ `Retry-After`。`ClaudeClient.Failure.http` がそのまま文言にする |
| 残量の通知 | 応答ヘッダ `X-Budget-Limit` / `X-Budget-Used` / `X-Budget-Reset` |
| 月次の上限 | 日次とは別に持つ（日次は事故を止め、月次は採算を守る） |

```ts
// Durable Object：ユーザー 1 人ぶんの台帳。呼び出しはここで直列化される。
export class Budget {
  async fetch(req: Request) {
    const { kind, amount } = await req.json();
    const day = new Date().toISOString().slice(0, 10);          // UTC 固定
    let s = (await this.state.storage.get<Ledger>(day)) ?? { used: 0, held: 0 };

    if (kind === "reserve") {                                    // 開始前：仮押さえ
      if (s.used + s.held + amount > DAILY_LIMIT) return json({ ok: false }, 429);
      s.held += amount;
    } else {                                                     // 終了後：実測で精算
      s.held = Math.max(0, s.held - amount.reserved);
      s.used += amount.weighted;
    }
    await this.state.storage.put(day, s);                        // 翌日ぶんは別キー
    return json({ ok: true, used: s.used, limit: DAILY_LIMIT });
  }
}
```

上限値はプランごとに価格から逆算している（$1 = ¥148、手数料 15%）。
重み付けの係数が原価比と同じなので、**原価 ＝ 重み付きトークン × そのモデルの入力単価**になる。

| プラン | モデル | 月額の手取り | 原価に充てる割合 | 月の上限 | 1 日の上限 |
|---|---|---|---|---|---|
| トライアル | Haiku 4.5（1M あたり $1） | ¥0 | —（最悪 $0.14 ≈ ¥21） | **14 万**（7 日の合計） | **2 万** |
| Pro | Sonnet 5（1M あたり $2） | ¥595 | 30%（¥178） | **60 万** | **8 万** |
| Max | Opus 5（1M あたり $5） | ¥2,303 | 40%（¥921） | **120 万** | **16 万** |

- 月の上限は採算を守る値。ゲートウェイの `PLANS`（`Gateway/src/config.ts`）が正
- 1 日の上限は月の上限を数日で使い切らせないための値（Pro と Max は月の 1/7.5）
- トライアルは Pro の月の上限を 7 日に日割りした 14 万を合計とし、1 日 2 万に区切る
- **モデルはゲートウェイがプランを見て上書きする**。アプリが何を指定しても、Pro が Opus を呼ぶことはない
- 月の上限に当たると 429（`scope: "monthly"`）。アプリは `ClaudeClient.Failure.monthlyLimitReached` にして、
  来月まで戻らないことを伝える。Max を案内するのは Pro の人だけ（Opus で呼んでいた＝ Max の人には出さない）
- 年額の契約者は 1 か月あたりの手取りが少ないので、原価に充てる割合は上の値を超える（§5.7）
- 採算の計算はゲートウェイのテスト（「月の上限を使い切っても…」）が確かめている。
  上限を変えて採算が崩れるとテストが落ちる

**実データが出るまでは仮の値**。変えるときはゲートウェイの `PLANS` と
アプリの `TokenBudget.daily(for:)`（トライアルは `TRIAL` と `TokenBudget.trialDaily`）を同じ数字にする（食い違うと「アプリでは残っているのに 429」になる）。

### 5.7 価格（2026-09-26 決定）

| プラン | モデル | 月額（税込） | 年額（税込） | 期間 |
|---|---|---|---|---|
| **トライアル** | Haiku 4.5 | **無料** | — | **7 日**（1 端末 1 回。自動課金なし） |
| **Pro** | Sonnet 5 | **¥770** | **¥7,700** | 自動更新 |
| **Max** | Opus 5 | **¥2,980** | **¥29,800** | 自動更新 |

- 年額はどちらも月額の 10 か月分（12 か月払うより 17% 安い）
- **Max は Pro の上位プラン**。月の上限に当たる人・もっと使いたい人向けで、機能は同じ。
  違いはモデル（Opus）と使える量（Pro の 2 倍）だけ
- 無料枠の呼び出しは、ゲートウェイが Haiku 4.5 に上書きする（§5.2）
- BYO キーの人は Sonnet 5（`ClaudeClient.model`。自分の請求なので上限は掛けない）
- Pro と Max は**最初から課金**（App Store の無料トライアルは付けない）。試したい人はトライアルを使う
- アップグレードの導線: 設定画面の「Max にアップグレード」（Pro の契約者にだけ出る）と、
  月の上限に当たったときの文言。Paywall は Pro の契約者には Max だけを並べる

**手取りと原価率** — 日本のストアは税込表示で、Apple は消費税 10% を引いてから手数料を取る。
原価は月の上限を使い切った場合の最悪値（Pro ¥178、Max ¥888。§5.6）。

| | 税抜 | 手取り / 月（手数料 15%） | 原価率 | 残る割合 |
|---|---|---|---|---|
| Pro 月額 ¥770 | ¥700 | ¥595 | 30% | **70%** |
| Pro 年額 ¥7,700 | ¥7,000 | ¥496（年 ¥5,950） | 36% | **64%** |
| Max 月額 ¥2,980 | ¥2,709 | ¥2,303 | 39% | **61%** |
| Max 年額 ¥29,800 | ¥27,091 | ¥1,919（年 ¥23,027） | 46% | **54%** |

| 前提 | 外れたとき |
|---|---|
| 手数料 15%（App Store Small Business Program に**申請が要る**） | 30% だと Pro 月額で 64%、Max 月額で 53% しか残らない |
| $1 = ¥148 | 円安になるほど原価率が上がる |
| 上限を使い切る人は少ない | 最悪値で計算しているので、普通の使い方なら残る割合はもっと高い |

**トライアルの持ち出し** — 1 人あたり最悪で 14 万 × Haiku（$1 / 1M）＝ $0.14 ≈ ¥21。
Pro 月額 1 か月分の手取りの 4% 未満なので、トライアルから 1/25 以上が Pro に移れば元が取れる。

App Store の価格帯に ¥770 / ¥7,700 / ¥2,980 / ¥29,800 があるかは App Store Connect で要確認。
無ければ近い価格帯を選ぶ（上の計算はほぼそのまま使える）。

### 5.8 無料トライアル（アプリ内）

App Store を通さない、7 日間の独立したプラン。**支払いの登録なしで始まり、終われば無料に戻る**。
Paywall の一番上に「7 日間の無料トライアル」として並ぶ（まだ使っていない人にだけ）。

| 決めごと | 理由 |
|---|---|
| 期間中は**全機能**を開ける（`Entitlement.isPro` が true） | 何が買えるのかを、壁ではなく体験で見せる |
| モデルは **Haiku に固定**（ゲートウェイが上書き） | 1 人あたりの原価を最悪 ¥21 に抑える。Pro（Sonnet）との違いも残る |
| 上限は合計 14 万・1 日 2 万 | Pro の月の上限を 7 日に日割り。初日に使い切って残りの 6 日が空になるのを防ぐ |
| 合計は**台帳の全期間の合計**（`Limits.total`）で数える | 月の枠で代用すると、月をまたいだ時点で数え直されて 14 万を超えられる。台帳 `trial:<端末 ID>` はトライアル専用なので、全期間の合計 ＝ 7 日間の合計 |
| **1 端末 1 回**（端末 ID ＋ DeviceCheck の bit1） | 入れ直しても端末 ID が同じなので、期間中ならそのまま続き、終わっていればやり直せない。初期化しても bit1 で止める |
| 開始時刻の正はゲートウェイ（台帳 `trial:<端末 ID>`） | 端末の時計を動かしても延びない。アプリは終了時刻の写しを持つだけ |
| 自動課金しない | 「知らないうちに請求された」を起こさない。続けたい人は Pro を買う |

```
Paywall「7 日間の無料トライアル」
  → POST /v1/trial/start（セッション JWT ＋ DeviceCheck の端末トークン）
      ├ 台帳に開始時刻あり → 期間内なら同じ終了時刻を返す / 過ぎていれば 409 ended
      ├ bit1 が立っている   → 409 device_used（端末を初期化した場合もここ）
      └ どちらも無い        → 開始時刻を書き、bit1 を立てて 200 { endsAt }
以後の /v1/messages: 契約 → トライアル中か → 無料枠 の順に見る
```

合計に当たると 429（`scope: "total"`、`Retry-After` なし）。アプリは
`ClaudeClient.Failure.trialLimitReached` にして、待っても戻らないことと Pro / Max を案内する。

**Shipaton の審査員向け** — トライアルは App Store を通らないので、RevenueCat の課金を試してもらうには
App Store Connect で **オファーコード**（Pro / Max の無料期間）を発行して渡す。

### 5.9 端末の見分け方（端末 ID × App Attest × DeviceCheck）

ログインは無い。それでも「同じ人（端末）が無料枠やトライアルを二重に使う」「入れ直して上限を白紙に戻す」を
止めるために、**3 つを重ねて**端末を見分ける。

#### 土台: Keychain に置く端末 ID

よく知られた方法と同じ考え方が土台にある。

1. 初回起動で UUID を作り、Keychain に保存する
2. その UUID をサーバに送り、サーバはそれを「匿名ユーザー」の ID として扱う
3. 無料枠・トライアル・契約・使用量を「UUID ○○ が使った」とサーバに記録する
4. 入れ直しても Keychain から同じ UUID が読めるので、サーバは同じ端末だと判断できる

`identifierForVendor` を使わないのは、同じ開発元のアプリをすべて削除するとリセットされるため。
Keychain は**アプリを削除しても残る**ので、この用途に向いている。

ただし、この土台だけでは 2 つの穴が残る。

| 穴 | 何が起きるか |
|---|---|
| **UUID はただの文字列** | アプリを改造するか、サーバを直接叩いて毎回違う UUID を送れば、そのたびに「新しい匿名ユーザー」になり、無料枠やトライアルを何度でも使える |
| **Keychain は消えることがある** | 「削除しても残る」は Apple が保証した仕様ではない（過去に iOS のベータ版で、削除時に消える方向へ変わりかけたことがある）。**端末を初期化すれば確実に消える** |

そこで 2 つを足す。

#### 3 つの層

| 層 | 何か | どこにあるか | 止めるもの | 入れ直し | 初期化 |
|---|---|---|---|---|---|
| **端末 ID** | アプリが作る UUID（`DeviceIdentity.id`） | 端末の Keychain（**この端末限定** `ThisDeviceOnly`） | 入れ直しで使用量・無料枠・トライアルを白紙に戻すこと | 残る | 消える |
| **App Attest** | Apple が保証する「本物のアプリ」の鍵と署名 | 鍵は端末の Secure Enclave、公開鍵はゲートウェイの KV | **改造したアプリやスクリプトが好きな UUID を名乗ること** | 作り直される | 作り直される |
| **DeviceCheck** | 端末ごとの 2 ビット（bit0 = 今月の無料枠を開始、bit1 = トライアルを使用） | **Apple のサーバ** | 初期化して端末 ID ごと作り直し、無料枠・トライアルをやり直すこと | 残る | **残る** |

役割の分担:

- **端末 ID** が主キー。契約・使用量・無料枠・トライアルは全部これで数える（§5 冒頭のまとめ）。
  RevenueCat の appUserID も同じ値にする
- **App Attest** は「その端末 ID を送ってきたのが本物のアプリか」を確かめる。
  初回に**鍵（keyId）と端末 ID を結びつけ**、以後は変えさせない。署名する平文は「チャレンジ.端末 ID」
- **DeviceCheck** は最後の砦。端末 ID が消えたときだけ効けばよいので、見るのは台帳が白紙のとき（初回）だけ

`ThisDeviceOnly` にするのは、バックアップや iCloud キーチェーンで**別の端末に同じ ID を持ち込ませない**ため。
機種変更すると新しい端末 ID になる（契約は RevenueCat の「購入を復元」で新しい端末に移る）。

#### 流れ

```
初回起動
  └ DeviceIdentity.id … Keychain に無ければ UUID を作って保存（ThisDeviceOnly）
  └ Purchases.configure(appUserID: 端末 ID) … RevenueCat 上のユーザーも端末 ID

セッション（24 時間に 1 回）
  POST /v1/challenge → チャレンジ
  初回:     attestKey で鍵を作り、「チャレンジ.端末 ID」で attestation → サーバが検証し、keyId ↔ 端末 ID を保存
  2 回目〜: generateAssertion で署名 → サーバが署名・カウンタ・keyId ↔ 端末 ID の一致を確認
  入れ直し後: Keychain に keyId だけ残り鍵の本体は無い → invalidKey → keyId を捨てて初回と同じ手順
              （新しい鍵が同じ端末 ID に結びつく）
  → JWT（sub = 端末 ID, kid = keyId）

AI の呼び出し（JWT の sub ＝ 端末 ID で全部引く）
  契約中か      … RevenueCat に端末 ID で照会（キャッシュ `sub:<端末 ID>`）
  トライアルか  … 台帳 `trial:<端末 ID>` の開始時刻
  無料枠        … 台帳 `free:<端末 ID>` の回数。行が無いときだけ DeviceCheck の bit0 を見る
  使用量        … 台帳 `<端末 ID>`（契約）/ `trial:<端末 ID>`（トライアル）

トライアルの開始
  台帳 `trial:<端末 ID>` に記録があるか → あれば続き or 終了済み
  無ければ DeviceCheck の bit1 → 立っていれば使用済み（初期化してやり直そうとした場合）
```

#### 場面ごとの結果

| 場面 | 端末 ID | 何が起きるか |
|---|---|---|
| アプリを入れ直す | 同じ | 使用量・無料枠・トライアルは続きから。契約もそのまま。App Attest の鍵だけ作り直される |
| 改造したアプリ・スクリプトが別の UUID を名乗る | — | App Attest の検証に通らず、セッションが取れない（401） |
| 本物のアプリの鍵で、別の端末 ID を名乗る | — | keyId ↔ 端末 ID の結びつきと合わず、401 |
| 端末を初期化する（Keychain も消える） | 新しい | 台帳は白紙になるが、DeviceCheck が残っているので今月の無料枠とトライアルはやり直せない |
| バックアップから別の端末に復元する | 新しい（`ThisDeviceOnly` なので移らない） | 別の端末として扱う。契約は「購入を復元」で移る |
| 1 つの Apple ID で 2 台 | 端末ごとに別 | 最後に「購入を復元」した端末が契約を持つ（RevenueCat の Transfer） |
| シミュレータ（開発） | Keychain に作る | App Attest の代わりに合言葉（`ATTEST_MODE = "off"`、DEBUG のみ）。DeviceCheck は効かない |

#### 限界

- **DeviceCheck を設定しない**（`DEVICECHECK_*` の秘密を入れない）と、初期化で無料枠とトライアルが戻る。
  そのときも無料枠全体の出費は共有プール（`FREE_POOL_*`）の天井で止まる
- DeviceCheck は 2 ビットしか持てないので、「20 回のうち何回」は台帳でしか数えられない。
  初期化されると、今月の無料枠は（残りがあっても）使えなくなる。安全側に倒している
- 端末 ID は**端末を見分けるだけ**で、人を見分けない。1 人が複数の端末を持てば、端末の数だけ無料枠とトライアルがある
- Apple や RevenueCat が落ちているときは、無料ユーザーやトライアルを締め出さない方に倒す（総額は天井で守る）

#### コードの場所

| 役割 | アプリ | ゲートウェイ |
|---|---|---|
| 端末 ID | `DeviceIdentity`（`AI/Entitlement.swift`）、`Keychain.write(thisDeviceOnly:)` | JWT の `sub` |
| App Attest | `GatewaySession.authenticate`（`invalidKey` で作り直し） | `session.ts` / `attest.ts`（KV の `key:<keyId>` に公開鍵と端末 ID） |
| DeviceCheck | `GatewaySession.deviceToken` | `devicecheck.ts`（`bitsForFreeMark` / `bitsForTrialMark`）、`free.ts`、`trial.ts` |
| RevenueCat | `SubscriptionService.start`（`appUserID: DeviceIdentity.id`） | `subscription.ts`（`sub:<端末 ID>`） |

---

## 6. データモデル

```sql
CREATE TABLE nodes (
  id          TEXT PRIMARY KEY,
  parent_id   TEXT REFERENCES nodes(id) ON DELETE CASCADE,
  para        TEXT NOT NULL,          -- projects|areas|resources|archives
  seg         INTEGER NOT NULL,       -- この階層の番号
  code        TEXT NOT NULL,          -- マテリアライズ済み "3152"
  path        TEXT NOT NULL,          -- "/Areas/生活/旅行/保険"
  title       TEXT NOT NULL,
  depth       INTEGER NOT NULL,
  sort_order  INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

CREATE TABLE notes (
  id           TEXT PRIMARY KEY,
  node_id      TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  layer        TEXT NOT NULL,         -- raw|knowledge|journal
  filename     TEXT NOT NULL,
  title        TEXT NOT NULL,
  body         TEXT NOT NULL,         -- Markdown 原文
  source_url   TEXT,
  occurred_at  INTEGER NOT NULL,      -- その日その時
  day_key      TEXT NOT NULL,         -- 'yyyy-MM-dd' カレンダー索引
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  deleted_at   INTEGER
);

CREATE VIRTUAL TABLE notes_fts USING fts5(
  title, body,
  content='notes', content_rowid='rowid',
  tokenize='trigram'          -- 日本語の部分一致に必要
);
-- notes への INSERT / UPDATE / DELETE はトリガで索引に反映する

CREATE TABLE messages (
  id          TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL,
  role        TEXT NOT NULL,          -- user|assistant
  content     TEXT NOT NULL,
  note_id     TEXT REFERENCES notes(id),
  created_at  INTEGER NOT NULL
);

-- 無料枠の消費数（v2）。課金状態そのものは RevenueCat 側が正なので持たない。
CREATE TABLE feature_usage (
  feature  TEXT NOT NULL,             -- ProFeature.rawValue
  period   TEXT NOT NULL,             -- 'yyyy-MM' 暦月でリセット
  count    INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (feature, period)
) WITHOUT ROWID;

-- 1 日のトークン消費（v3）。応答の usage をそのまま積む。
-- 上限の根拠はゲートウェイ側にあり、この表はその鏡（§5.6）。
CREATE TABLE token_usage (
  day         TEXT PRIMARY KEY,       -- 'yyyy-MM-dd'
  input       INTEGER NOT NULL DEFAULT 0,
  output      INTEGER NOT NULL DEFAULT 0,
  cache_read  INTEGER NOT NULL DEFAULT 0,
  requests    INTEGER NOT NULL DEFAULT 0,
  updated_at  INTEGER NOT NULL
) WITHOUT ROWID;
```

スキーマ版数は `user_version`。v2 で `feature_usage`、v3 で `token_usage` を足す。
どちらも追加のみで、既存データは触らない。

---

## 7. モジュール構成

```
JournalMate/
├ App/
│  ├ JournalMateApp.swift    エントリポイント・DB 起動・DI
│  └ RootView.swift          3 タブ ＋ オンボーディング提示
├ Core/                      ← iOS 非依存。Verification で検証できる層
│  ├ SQLite.swift            libsqlite3 の薄いラッパ
│  ├ Schema.swift            スキーマとマイグレーション
│  ├ Models.swift            Para / Layer / Node / Note / Message
│  ├ ParaCode.swift          番号体系・ファイル名規約
│  ├ Store.swift             リポジトリ（唯一の DB 出入口）
│  ├ Store+Paths.swift       パス解決・ジャーナル案のコミット
│  ├ Usage.swift             ProFeature / 無料枠の解放判定（純粋関数）
│  ├ VaultExporter.swift     実 .md 書き出し（zip）
│  └ MemoImporter.swift      外部メモの読み取り・受信箱への投入
├ AI/                        ← iOS 非依存
│  ├ ClaudeClient.swift      Messages API（ストリーミング＋ツール呼び出し）
│  ├ JournalExtractor.swift  会話 → ジャーナル案
│  ├ RecallIntent.swift      会話 → 検索意図（何を・どのフォルダで・どんな言葉で探すか）（Pro）
│  ├ JournalRecall.swift     過去のジャーナルを探す道具（glob / grep / read）（Pro）
│  ├ Entitlement.swift       無料/Pro 判定・呼び先の解決・Keychain
│  └ BillingConfig.swift     RevenueCat の公開キー・ゲートウェイ URL
├ Billing/                   ← RevenueCat / DeviceCheck 依存
│  ├ SubscriptionService.swift  Offering 取得・購入・復元・購読状態の反映
│  ├ GatewaySession.swift    App Attest → 中継サーバのセッショントークン
│  └ PaywallSheet.swift      Paywall と、一覧に出す鍵つきの行
├ Resources/
│  └ Localizable.xcstrings   翻訳（英語キー → 日本語）。§4.9
└ Features/                  ← iOS 専用（UIKit / SwiftUI）
   ├ Chat/       ChatScreen / ChatViewModel / JournalDraftSheet
   ├ Calendar/   CalendarScreen / CalendarViewRepresentable / CalendarFilterBar
   ├ Tree/       TreeScreen / NodeScreen / LayerScreen / NoteDetailScreen
   ├ Onboarding/ OnboardingScreen
   └ Settings/   SettingsScreen / MemoImportScreen
```

中継サーバは別立てで `Gateway/`（Cloudflare Workers / TypeScript）。

```
Gateway/
├ src/
│  ├ index.ts          ルータ。認証 → 購読 → 上限 → 中継
│  ├ session.ts        チャレンジと App Attest によるセッション発行
│  ├ attest.ts         attestation / assertion の検証
│  ├ subscription.ts   RevenueCat 照会・Webhook・キャッシュ
│  ├ free.ts           未契約者の無料枠（回数・モデル固定・端末の見分け）
│  ├ trial.ts          無料トライアル（7 日・Haiku・1 端末 1 回）
│  ├ devicecheck.ts    DeviceCheck の 2 ビット（入れ直し対策）
│  ├ budget.ts         Durable Object の台帳（仮押さえ → 精算）
│  ├ proxy.ts          body の検査・SSE の素通しと計量
│  ├ jwt.ts / cbor.ts / bytes.ts / http.ts / config.ts
└ test/gateway.test.ts  70 項目（vitest）
```

---

## 8. 検証

`Verification/run.sh` は `Core/` と `AI/` を macOS 向けにビルドして実行する。
UI を除く全ロジックが Xcode なしで検証できる。確認している内容:

- ルートの先頭桁（Journal 1 / PARA 2〜5）と自動採番、明示採番（3152 の再現）、v3 → v4 の番号移行
- 階層をまたぐ移動で `code` / `path` / `para` / `depth` / ファイル名が子孫まで引き直されること
- 移動しても**本文は書き換わらない**こと（非破壊の再分類）
- 自分の子孫には移動できないこと
- 日本語の全文検索（trigram）と 2 文字クエリの LIKE フォールバック
- 日付索引とカレンダー装飾の集計
- カレンダーの絞り込み（§4.2）: PARA ルートの前方一致でその PARA だけになること、
  チェックしたフォルダだけになること、複数チェックが和集合になること、
  **装飾の集計と当日の一覧が同じ条件で絞られること**、空振りする前方一致で 0 件になること
- Vault 書き出し（実 .md 階層と YAML frontmatter）
- 外部メモの取り込み: ファイル名の日付 8 形式の解釈、数字の誤認しないこと、
  元のフォルダ名が受信箱の下に残ること、**メモ作成日が `occurred_at` になること**、
  作成日を復元できた件数と代用した件数の内訳、二重取り込みを弾くこと
- 書き出した Vault の読み戻し（frontmatter から `path` / `layer` / 日時が戻ること）
- 会話 → フォルダへの振り分け（§4.1.1）の AI 呼び出し以外すべて: 一覧に受信箱を載せないこと、
  存在しないコードと重複を捨てること、**PARA がフォルダ側から決まること**、
  新しいパスの `/` と PARA 名の除去・既存パスとの突き合わせ・深さ 3、選んだフォルダに保存されること、
  文字の返事の解き方（名前 → 相づち、決められなければ推測しない）、会話を 1 本のテキストにすること
- 受信箱の名前（§4.9）: 別の言語の名前で作られた受信箱も見つかること、
  既存の受信箱の名前を使い続けること。受信箱のパスを確かめる項目は
  `MemoImporter.inboxTitle` を使う（macOS の検証ビルドには翻訳が無く `Inbox` になるため）
- 課金: 解放判定の境界（無料枠の初回・最後の 1 回・使い切り）、Pro 専用機能に枠が無いこと、
  消費が機能ごと・暦月ごとに別勘定で積まれること、**月が変われば枠が戻ること**
- 呼び先の解決: BYO キーは Anthropic 直・契約者はゲートウェイ経由で、
  **ゲートウェイには API キーを載せないこと**
- トークンの上限: 出力の重み付けとキャッシュの割引、日をまたいだら 0 に戻ること、
  空の usage を記録しないこと、余白を切ったら新しい呼び出しを始めさせないこと、
  応答の `usage` の読み取り（項目が欠けても落ちない）
- プラン: Pro は Sonnet・Max は Opus・トライアルは Haiku、1 日の上限（Max は Pro の 2 倍、
  トライアルは Pro の月の上限を 7 日に日割りして 1 日ずつに区切った値）、
  月の上限の 429 が専用の失敗になり、日次の 429 はこれまで通りであること

### 8.1 中継サーバ（`Gateway/`）

`npm test` が確かめている 70 項目:

- 購読状態のキャッシュ: 1 時間は使う、アプリの申告（`X-Plan`）と食い違えば聞き直す
  （購入直後・Pro → Max）、聞き直しは 1 分に 1 回まで、申告が無ければ聞き直さない
- プラン: Pro は Opus を指定しても Sonnet に差し替える、Max は Opus で呼ぶ、
  `max` を `pro` より先に見る、期限切れのエンタイトルメントを無視する、
  **月の上限を使い切っても原価が手取りの取り決め（Pro 30%・Max 40%）以内に収まる**
- body の検査: 許可外のモデルを弾く、知らないキーを落とす、`max_tokens` に上限を被せる、
  大きすぎる本文・空の messages を弾く
- 計量: 出力の重み付けとキャッシュの割引、応答の `usage` の読み取り、
  **SSE を素通ししながら数えられること**（チャンクが行の途中で切れても、壊れた行があっても）
- 台帳: 仮押さえも上限に数える（同時に走っても越えない）、精算で押さえが外れること、
  落ちた接続の押さえが時間で消えること、押さえが消えていても実測は積むこと、
  日次と月次を別に見ること、**日と月を UTC で切ること**
- セッション: JWT の発行と検証、別の鍵・改竄・期限切れが通らないこと
- App Attest の部品: CBOR の読み取り、authData のカウンタと aaguid、
  DER 署名の r‖s への変換、証明書からの nonce の取り出し
- 無料枠: 無料で呼べる機能と回数、Pro 専用の機能が無料で呼べないこと、
  **モデルと出力上限をサーバが上書きすること**、回数を機能ごと・月ごとに数えること
- DeviceCheck の判定: 今月立てたビットは使用済み、**先月のビットは古いので今月は使える**、
  一度も書いていない端末は使える。無料枠の印を付けてもトライアルの印が残ること、
  トライアルの印を付けるときに先月の無料枠の印を落とすこと
- 無料トライアル: 7 日間だけ有効、Haiku で呼ぶ、合計が Pro の月の上限の 7/30 で 1 日の上限 × 7 と一致、
  **合計の上限は月をまたいでも数え直さない**、精算で合計にも積む、合計を渡さない台帳（Pro / Max）は合計で止めない

**Apple の証明書まわりだけは実機の attestation を通していない。**
確かめているのは部品までで、鎖の検証と nonce の突き合わせは実機で 1 回通す必要がある。

---

## 9. 未決事項

手を動かす順の作業一覧は [todo.md](todo.md) に。ここは設計として決まっていない点だけ。

- 中継サーバの実機確認（App Attest を実機で 1 回通す）— §8.1
- 中継サーバのデプロイ（KV の作成・Apple ルート CA と秘密の投入・Webhook の設定）
- App Store Connect / RevenueCat の商品登録（価格は §5.7 で決定済み）
- トークン上限（Pro 日次 8 万・月次 60 万、Max 日次 16 万・月次 120 万）の水準 — 価格からの逆算で、実データが出るまでは仮の値
- iCloud 同期（CloudKit で SQLite を同期するか、レコード単位にするか）
- 画像添付 UI

---

## 10. 実行コマンド

作業ディレクトリは `/Users/apple/Documents/Code/journal-mate`。

### 10.1 初回だけ必要な準備

Xcode 27 は入っているが、ライセンス未同意だと `xcodebuild` も `simctl` も動かない。
`xcode-select` が Command Line Tools を指している場合も切り替える。**一度だけ実行する。**

```sh
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
```

確認:

```sh
xcodebuild -version                       # Xcode 27.0 が出れば OK
xcodebuild -showsdks | grep -i ios        # iOS SDK が見えれば OK
```

### 10.2 アプリをビルドする

```sh
open JournalMate.xcodeproj                # Xcode で開く（⌘R で実行）
```

コマンドラインから:

```sh
xcodebuild -scheme JournalMate \
  -destination 'generic/platform=iOS Simulator' \
  build
```

### 10.3 シミュレータで動かす

```sh
# 使えるシミュレータを見る
xcrun simctl list devices available | grep iPhone

# ビルドして起動（デバイス名は上で出たものに置き換える）
xcodebuild -scheme JournalMate \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build

xcrun simctl boot 'iPhone 17 Pro'
open -a Simulator
```

言語を指定して起動する（§4.9。設定アプリを経由しない）:

```sh
APP=$(find ~/Library/Developer/Xcode/DerivedData -path '*Debug-iphonesimulator/JournalMate.app' | head -1)
xcrun simctl install 'iPhone 17 Pro' "$APP"
xcrun simctl launch 'iPhone 17 Pro' app.journalmate.JournalMate -AppleLanguages "(en)"   # 日本語は (ja)
```

### 10.4 データ層を検証する（Xcode 不要）

`Core/` と `AI/` は iOS 専用 API を使っていないので、macOS SDK だけでビルドして
**実際に動かして**確認できる。§8 の項目がすべて走る。

```sh
sh Verification/run.sh
```

期待する最終行:

```
すべて通過
```

### 10.5 型チェックだけしたいとき

```sh
# Core + AI を Swift 6 の厳格並行性つきで型チェック（依存なし・数秒）
xcrun swiftc -typecheck -swift-version 6 -target arm64-apple-macosx14.0 \
  JournalMate/Core/*.swift JournalMate/AI/*.swift

# 全ファイルの構文チェック（UI 含む。iOS SDK 不要）
for f in $(find JournalMate -name '*.swift'); do
  xcrun swiftc -frontend -parse "$f" || echo "NG: $f"
done
```

### 10.6 DB を覗く

シミュレータ上の実体を直接開く。

```sh
DB=$(find ~/Library/Developer/CoreSimulator/Devices \
       -name 'JournalMate.sqlite' 2>/dev/null | head -1)
sqlite3 "$DB" 'SELECT code, path FROM nodes ORDER BY code;'
sqlite3 "$DB" 'SELECT filename, title FROM notes WHERE deleted_at IS NULL ORDER BY occurred_at DESC LIMIT 20;'
```

### 10.7 検証状況

| 対象 | 状態 |
|---|---|
| §10.4 データ層の実行検証（176 項目） | **通過済み** |
| §10.5 Core + AI の型チェック | **通過済み** |
| §10.5 全ファイルの構文チェック | **通過済み** |
| §10.2 アプリ本体のビルド（iOS Simulator） | **通過済み** — 警告 0 |
| §10.3 シミュレータでの動作 | **一部** — カレンダーの絞り込み（§4.2）だけ、仮データを入れて描画を確認（2026-09-24）。オンボーディングの 1 画面目を en / ja で起動して表示を確認（2026-09-26）|
| §4.9 翻訳の漏れ | **確認済み** — ビルドで抽出されたキー（`.stringsdata`）がすべてカタログにあり、`%lld` / `%@` の数と種類が英語と日本語で一致（2026-09-26）|
| §4.9 設定アプリの「言語」からの切り替え | **未実施** — 設定画面の「言語」の行と、設定アプリ側での切り替えは実機かシミュレータで要確認 |
| §8.1 中継サーバのテスト（70 項目・vitest） | **通過済み** |
| 中継サーバの型チェックとバンドル（`wrangler --dry-run`） | **通過済み** |
| 実機での App Attest | **未実施** — §8.1 |
| 実機での DeviceCheck（入れ直しで枠が戻らないこと） | **未実施** |

`xcode-select` が Command Line Tools を指しているときは、§10.1 を実行するか、
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` を付けて `xcodebuild` を呼ぶ。

課金の UI（`Billing/`）は RevenueCat SDK 未追加の状態でビルドを確認している。
SDK を足した後の経路（`#if canImport(RevenueCat)` の中身）は、実機での購入と合わせて要検証。
