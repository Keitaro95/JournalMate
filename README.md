# JournalMate

AI との対話がそのまま日々のジャーナルになり、**PARA × メダリオンアーキテクチャ**で
自動的に整理されていく iOS アプリ。

設計の詳細と、ストレージ方式を選んだ理由は [development.md](development.md) に、
残っている作業は [todo.md](todo.md) にあります。

## ビルド

Xcode のライセンスにまだ同意していない場合は、最初に一度だけ実行してください。

```sh
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
```

その後:

```sh
open JournalMate.xcodeproj
# または
xcodebuild -scheme JournalMate -destination 'generic/platform=iOS Simulator' build
```

- 依存パッケージなし（SQLite は OS 標準の `libsqlite3` を直接使用）
  課金を有効にするときだけ RevenueCat を足します（[§5.5](development.md#55-導入の段取り)）
- 最小 iOS 18.0 / Swift 6

## 検証

データ層（`Core/` + `AI/`）は iOS 専用 API を使っていないので、Xcode なしで実際に動かせます。

```sh
sh Verification/run.sh
```

PARA の番号採番、階層をまたぐ移動時の code / path / ファイル名の引き直し、
日本語の全文検索、カレンダー索引、Vault 書き出し、課金の解放判定とトークン上限までを
実行して確認します。

中継サーバは別立てです。

```sh
cd Gateway && npm install && npm test
```

## 3 つの画面

| タブ | 役割 |
|---|---|
| Chat | AI と対話し、その会話からジャーナルを記録する（メイン） |
| Calendar | `UICalendarView` で日付を選び、その日のジャーナルを PARA タグ付きで見る |
| Tree | PARA → 任意の階層 → `raw`/`knowledge`/`journal` → `.md` を辿る |

## ディレクトリ構造

```
Areas/                         ← PARA（先頭桁 3）
└ 生活/                        ← seg 1  → 31
   └ 旅行/                     ← seg 5  → 315
      └ 保険/                  ← seg 2  → 3152
         ├ raw/       3152_海外旅行保険の比較.md      ← Bronze: 原本
         ├ knowledge/ 3152_クレカ付帯で足りる条件.md   ← Silver: 教訓
         └ journal/   3152_202609191330.md           ← Gold: その日その時
```

コードは階層パスから導出され、ファイル名の先頭に付きます。実体は階層構造で、
コードは AI と grep のための検索キーです（`code LIKE '115%'` で部分木を一撃）。

## 課金

RevenueCat のサブスクリプション 1 本（エンタイトルメント `pro`）。
**記録そのものは課金しません。**データが溜まるほど価値が上がる設計なので、
入力を絞ると課金する理由の方が先に消えます。

| | 無料 | Pro |
|---|---|---|
| ジャーナル記録・カレンダー・ツリー・書き出し | ○ | ○ |
| 外部メモの取り込み（受信箱へ） | ○ | ○ |
| AI でのジャーナル抽出 / PARA 自動推定 | **月 20 回**（端末ごと） | 無制限 |
| AI チャット | × | ○ |
| 過去のジャーナルから引き出す（過去の記録を踏まえた語りかけ・「あの時どうしてたっけ」） | × | ○ |

自分の Claude API キーを入れた人は、契約しなくても全部使えます（上級者向けの逃げ道）。

AI の呼び出しは中継サーバ（[Gateway/](Gateway/README.md)・Cloudflare Workers）を通します。
**Anthropic の API キーをアプリに埋め込まない**ためで、そこで App Attest による認証、
購読の確認、1 日あたりのトークン上限、無料枠の回数をまとめて見ています。

無料枠は **DeviceCheck** で端末に紐づけているので、アプリを入れ直しても戻りません
（Apple 側に残る 2 ビットで「この端末は今月の無料枠を開始した」を覚えます）。

課金の全体像は [development.md §5](development.md#5-課金) に。RevenueCat SDK を
Swift Package で足すまでは `#if canImport(RevenueCat)` で無効になり、
課金は「未設定」として動きます。ユーザーに Claude API キーを入れさせる経路はありません。

## データの持ち方

正は **SQLite 1 ファイル**、本文は **Markdown 文字列**、ディレクトリは **仮想**。
設定画面から実体の `.md` 階層（YAML frontmatter 付き・Obsidian 互換）を
zip で書き出せます。理由は [development.md §2](development.md#2-ストレージ方式の結論最重要論点) に。

アプリを削除すると記録はすべて消えます（オンボーディングの最後のページで伝えている）。
書き出した zip には DB の写し `journalmate-backup.sqlite` も入っていて、入れ直したあと
設定 >**バックアップから復元** でその zip（または展開したフォルダ）を選ぶと、
フォルダ・ジャーナル・会話が丸ごと戻ります（今の中身は置き換え。利用量の記録は端末側を残す）。

## すでにあるメモを入れる

設定 >**外部からメモを登録** から、フォルダごとまとめて取り込めます。
Resources / 受信箱 / 〈元のフォルダ名〉 に `raw`（原本）として入り、分類は後から動かせます。

メモ.app には一括書き出しが無いので、画面に **ショートカットの作り方を図で載せています**。
肝はファイル名を `〈作成日 yyyyMMddHHmm〉_〈名前〉.txt` にすること。
書き出した .txt のファイル日付は「書き出した日」になるため、
**元のメモ作成日を運べる経路はファイル名（か frontmatter）だけ**です。
代用になった件数は取り込み後に警告として出ます。詳細は
[development.md §4.5](development.md#45-外部メモの取り込み設定--外部からメモを登録) に。

取り込んだあと、設定 >**受信箱を AI で分類** で、
**すでにあるディレクトリ構造を先に読み込んでから**まとめて振り分けられます
（Pro）。既存に収まるものは既存へ、どこにも収まらないときだけ新しい
フォルダを提案し、判断がつかないものは受信箱に残します。提案は一覧で確認・除外してから
適用するので、勝手には動きません。移動しても本文とメモ作成日は変わりません。
