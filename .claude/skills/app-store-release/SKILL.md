---
name: app-store-release
description: JournalMate の iOS アプリを App Store Connect にアップロードし、審査に出すまでの手順。バージョンとビルド番号を上げる → テスト → Archive・アップロード → バージョン作成・ビルドの紐づけ・新機能の文・審査メモ → 審査に提出。「配信したい」「ビルドして」「TestFlight に上げて」「審査に出して」「App Store Connect」と言われたら使う。
---

# App Store Connect への配信と審査

JournalMate を App Store Connect に上げて審査に出すまでを、コマンドと API で進める。
大もとのルールは MARKETING.md の「## デプロイのルール」。この skill はその 2〜5 と提出を、手で画面を触らずに行うためのもの。手順が変わったら、両方を直す。

## 前提

- Xcode: この Mac は `xcode-select` が Command Line Tools を向いている。`xcodebuild` には `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` を付ける（スクリプトは付けてある）
- API キー: `~/.appstoreconnect/journalmate.env`（`ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_APP_ID`）と `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`。どちらもリポジトリに入れない（`*.p8` は .gitignore 済み。このリポジトリは GitHub にある）
  - 無いときは、ユーザーに App Store Connect >「ユーザとアクセス」>「統合」>「App Store Connect API」>「チームキー」で App Manager のキーを作ってもらう。.p8 は 1 回しかダウンロードできない。「ダウンロード」フォルダはターミナルから `mv` できない（macOS の保護）ので、Finder で `open ~/.appstoreconnect/private_keys` に動かしてもらう
  - .p8 の中身を会話に貼ってもらわない
- Python: `uv run` で動かす（依存はスクリプトの先頭に書いてある）

## 手順

### 1. 何が入るかを確かめる

- MARKETING.md を読み、いちばん新しい周の「施策と実装」と「このバージョンの新機能」の下書きを見る
- `uv run .claude/skills/app-store-release/scripts/asc.py status` で、App Store に出ているバージョン・上がっているビルド・審査の状態を見る
- **新機能の文は「App Store に出ている版」からの差分で書く。** TestFlight だけで止めた版（例: 1.0.1）の変更も含める

### 2. Gateway を先にデプロイする（`Gateway/` に変更があるときだけ）

`git log --oneline -- Gateway` で前回のデプロイより後の変更を見る。あれば `cd Gateway && npm test && npx wrangler deploy`。

### 3. バージョンとビルド番号を上げてコミットする

- `JournalMate.xcodeproj/project.pbxproj` の `MARKETING_VERSION` と `CURRENT_PROJECT_VERSION` をすべて書き換える（ターゲットごとに何か所もある）
- ビルド番号は、上がっている最新（status の一番上）より大きくする。同じ番号は二度上げられない
- コミット: `バージョン X.Y.Z (N)`

### 4. テスト

`sh Verification/test-all.sh`。10 分近くかかるので timeout を長めにする。Gateway のテストが出す `attest failed` / `KV put() limit exceeded` のログは想定どおりで、失敗ではない。

### 5. Archive してアップロードする

```sh
sh .claude/skills/app-store-release/scripts/upload.sh
```

- `Upload succeeded` と `EXPORT SUCCEEDED` が出れば成功。Archive の中身のバージョン・ビルド番号も表示される
- ストアでの処理に数分〜30 分かかる。`status` でそのビルドが `VALID` になるまで待つ

### 6. 新機能の文と審査メモを入れる

- 新機能の文をロケールごとに 1 ファイルにする（scratchpad に置く）。ストアの言語は今は日本語（`ja`）だけ。英語を足したら `--whats-new en-US=…` も渡す（足りないとスクリプトが止まる）
- 審査メモは `submission.md` の「#### 英語」のコードブロックがそのまま入る。**先にその中身が今のアプリの動き（無料の範囲・Paywall が出る場所・新しい機能の場所）と合っているかを確かめ、合っていなければ submission.md を直してコミットする**

```sh
uv run .claude/skills/app-store-release/scripts/asc.py prepare 1.0.3 5 --whats-new ja=<scratchpad>/whats-new-ja.txt
```

バージョンが無ければ作り（リリースは「承認後に自動」）、あればそれを直す。ビルドの紐づけ・新機能の文・審査メモを入れる。説明文・キーワード・スクリーンショットは触らない（変えるなら App Store Connect の画面で）。

### 7. 審査に出す

**ユーザーが「審査に出して」と言ったときだけ。** 出す前に、入れた新機能の文とビルドを見せる。デプロイのルール 6（TestFlight の実機確認）がまだなら、そのことも伝える。

```sh
uv run .claude/skills/app-store-release/scripts/asc.py submit 1.0.3
```

`WAITING_FOR_REVIEW` と出れば提出済み。`status` でも確かめられる。

### 8. 記録する

MARKETING.md の「施策と実装」に、バージョン・ビルド番号・日付・コミット・提出した時刻・入れた新機能の文を書く。まだのこと（実機確認・審査の結果）も書く。MARKETING.md は .gitignore に入っているので、コミットはしない。

## つまずいたところ

- `xcodebuild` が「requires Xcode」で止まる → `DEVELOPER_DIR` が無い
- API が 401 → `journalmate.env` の `ASC_KEY_ID` と .p8 のファイル名が合っているか。App 内課金用のキー（RevenueCat に渡したもの）では API は使えない
- 間違ったバージョンで上げてしまったビルドは、App Store Connect の TestFlight で期限切れにする（1.1.0 (3) がそう）
