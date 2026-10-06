# TODO

最終更新: 2026-10-06

---

## 最新タスク（2026-10-06〜）

- [x] **ノートの保存先をあとから変えられるようにする**（Folders から開いた .md の画面）（10/6 実装・ユニット / UI テスト通過）
  - [ ] 画面で目で確かめる: ノートを開く → パスを押す → 別のフォルダで「ここに移す」→ 戻って一覧・カレンダーを見る
  - いま: タイトルの上に出ているディレクトリ（`{node.path}/{layer}/`）はただの文字で、押しても何も起きない
    （[NoteDetailScreen.swift](JournalMate/Features/Tree/NoteDetailScreen.swift) の `header`）
  - これから: そのディレクトリを押すと、Journal タブで新しく書くときと**同じ** `FolderPickerSheet`
    （[JournalScreen.swift](JournalMate/Features/Journal/JournalScreen.swift) の `destinationRow` から開くもの）が出て、
    選んだサブフォルダへノートを移す。ピッカーの中でサブフォルダを足すこともそのままできる
  - 移す処理は既存の `Store.move(_:to:layer:)` を使う（本文と日付はそのまま。カレンダー上の位置は動かない）
  - ボタンだと分かる見た目にする（Journal タブの保存先の行と同じ、フォルダのアイコン付き）
  - 移したら「{フォルダ名}に移しました」と出し、ヘッダのディレクトリ・ナビゲーションのタイトルも新しい場所に変える。
    戻ったときに元のフォルダの一覧から消えていること
  - 確認: 移した後、カレンダーの絞り込み（PARA）・Folders の両方で新しい場所に出ること。`StoreTests` に「移した後の node_id とファイル名」を足す

---

## ★ RevenueCat Shipaton 2026 — 締め切り

**締め切り: 米国 9/30（水）23:45 PDT ＝ 日本 10/1（木）15:45**

- **締め切りまでに App Store で実際に公開されている**必要がある。
  提出物に公開済みアプリの URL が必須。アップデートではなく**初めて公開する新しいアプリ**であること
- 審査待ちを考えると、**遅くとも 9/27（日）までに審査へ提出**するのが現実的なライン
- 応募条件: RevenueCat SDK で**少なくとも 1 つのアプリ内課金**が動いていること
- 審査員向けに**無料トライアル**か、有料機能を試せる**プロモコード**を用意すること
  → アプリ内トライアルは App Store を通らないので、**Pro / Max のオファーコード**を渡す（§2）
- 文面の下書きは [submission.md](submission.md)

> **もし学生なら別ルートがある。** 新設の Next Gen Award（学生限定）は動画とオープンソースの
> コードで審査され、App Store での公開も有料の開発者アカウントも要らない。

---

## いまの状態

| | |
|---|---|
| アプリのビルド（iOS Simulator / 実機 Release） | 通過・警告 0 |
| データ層の検証（176 項目） | 通過 |
| 中継サーバのテスト（70 項目）・型チェック | 通過 |
| 実際に課金できるか | **まだ**（SDK は追加済み・ビルド通過。商品の登録と公開キーがまだ → §2） |
| 契約者・トライアル・無料枠で AI が使えるか | ゲートウェイはデプロイ済み（9/27）。**アプリからの呼び出しはまだ**（シミュレータは §3.1 の DEBUG モードで） |
| App Attest・DeviceCheck が本物の端末で通るか | **まだ**（実機で一度も通していない） |

プランの全体像は [development.md §5 のまとめ](development.md#5-課金)、
端末の見分け方は [§5.9](development.md#59-端末の見分け方端末-id--app-attest--devicecheck)。

---

## 今日〜明日（9/26〜27）: 提出までに必須

上から順に。後ろの作業ほど前の作業に依存している。

### 1. アカウントと契約 ― 手作業

- [ ] **Devpost で参加登録** — revenuecat-shipaton-2026.devpost.com で「Join hackathon」
- [x] **Apple Developer Program に登録**（9/28 承認）（承認待ちが一番のボトルネックになりうる）
      https://developer.apple.com/jp/help/account/membership/enrolling-in-the-app/
- [ ] **App Store Connect で契約・税・銀行口座を設定** — 有料アプリ契約（Paid Apps Agreement）が
      有効でないと課金を設定できない
- [ ] **App Store Small Business Program に申請** — 手数料が 30% → 15% になる。
      **価格と上限はすべて 15% 前提で計算してある**（development.md §5.7）。申請しないと手取りが約 2 割減る
- [ ] **App ID（`app.journalmate.JournalMate`）を登録し、App Store Connect でアプリを新規作成**。
      名前 `JournalMate` が取られていたら [submission.md](submission.md) の代案で
- [x] Xcode の Signing で Team を選ぶ（`DEVELOPMENT_TEAM` はまだ空）

### 2. 課金 ― 手作業（App Store Connect / RevenueCat / Xcode）

上から順に。**§1 の有料アプリ契約とアプリの新規作成が済んでいないと、2-1 のサブスクリプションは作れない。**
画面の名前は時期によって少し変わるので、見つからないときは近い名前を探す。

アプリ側（SDK の追加とビルド）は済んでいる。残りは管理画面の設定と、公開キーを入れることだけ。
キーが入るまでは、プラン画面は「サブスクリプションはまだご利用いただけません」と出し、
無料トライアルだけを選べる状態で動く。

- [x] **Xcode で `purchases-ios` を追加**（9/27・5.91.0）— `https://github.com/RevenueCat/purchases-ios`
      （Up to Next Major 5.0.0）、プロダクト `RevenueCat`。`Package.resolved` も作成済み
- [x] **すぐにビルドする**（9/27・エラーなしで通った）— `#if canImport(RevenueCat)` の中
      （`SubscriptionService` の購入・復元・`Purchases.configure(withAPIKey:appUserID:)`）を初めてコンパイル

#### 2-1. App Store Connect: サブスクリプションを 4 つ作る

場所: **アプリ → JournalMate → 左メニュー「収益化」→「サブスクリプション」**

- [x] **グループを作る**（9/28） — 「サブスクリプショングループ」の「＋」。参照名は `JournalMate Plans`（利用者には見えない）。
      グループの「App Store のローカリゼーション」に日本語・英語の表示名（例: 「JournalMate プラン」）
- [x] **グループの中に 4 つ作る**（9/28） — 「＋」で 1 つずつ。**製品 ID は 1 文字も変えない**
      （アプリは ID に `.max.` を含むかで Pro / Max を見分ける。`BillingConfig.maxProductMarker`）

  | 参照名 | 製品 ID | 期間 | 価格 |
  |---|---|---|---|
  | Pro Monthly | `app.journalmate.pro.monthly` | 1 か月 | ¥770 |
  | Pro Annual | `app.journalmate.pro.annual` | 1 年 | ¥7,700 |
  | Max Monthly | `app.journalmate.max.monthly` | 1 か月 | ¥2,980 |
  | Max Annual | `app.journalmate.max.annual` | 1 年 | ¥29,800 |

  1 つごとに入れるもの:
  - サブスクリプション期間と価格（基準国を日本に。ちょうどの額が無ければ一番近い額）
  - ローカリゼーション（日本語・英語）: 表示名（例: 「Pro 月額」）と説明（例: 「Claude Sonnet で AI の全機能」）
  - 審査用の情報: プラン画面のスクリーンショット 1 枚と審査メモ
  - **導入オファー（無料トライアル）は付けない** — 7 日間のトライアルはアプリ内の別プラン
- [ ] **ランクを決める** — グループ画面の並び順がランクになる
  - レベル 1（上）: Max Monthly / Max Annual
  - レベル 2: Pro Monthly / Pro Annual
  - こうすると Pro → Max はすぐ切り替わり差額は日割り、Max → Pro は次の更新日から切り替わる
- [x] **RevenueCat に渡す鍵を作る**（9/28） — **ユーザとアクセス → 統合 → アプリ内課金** で「生成」
  - **`.p8` ファイルをダウンロード（1 回しかできない）**
  - **キー ID** と、同じ画面の上にある **Issuer ID** を控える
- [ ] **Devpost の審査員向けのオファーコードを発行（公開後）** — Pro と Max それぞれ。submission.md の `XXXX` を埋める
  - **App Review の審査員向けのコードは不要**（sandbox で購入でき、課金されない。審査メモにそう書いてある）
  - オファーコードは本番の App Store でしか使えないので、**アプリとサブスクリプションが承認・公開されてから**
    App Store Connect → サブスクリプション → 各プラン → オファーコード で発行する
  - 自分・知り合い用は RevenueCat → Customers で相手のユーザー ID（設定 > サポートでコピーできる）を引き、
    **Grant Promotional Entitlement** で `pro` / `max` を付与する（コード不要）

#### 2-2. RevenueCat: 設定

場所: **app.revenuecat.com**

- [ ] **プロジェクトとアプリ** — Project を作る（名前 `JournalMate`）→「Apps & providers」→「App Store」を追加
  - App name: `JournalMate`、Bundle ID: `app.journalmate.JournalMate`
  - **In-App Purchase Key**: 2-1 の `.p8`・キー ID・Issuer ID を入れる → 保存してエラーが出ないこと
- [ ] **商品を読み込む** — 「Products」→「＋ New」か「Import」で 4 つの製品 ID を登録
- [x] **エンタイトルメント**（9/28）（ここが一番大事）— 「Entitlements」で 2 つ

  | 識別子 | 紐づける商品 |
  |---|---|
  | `pro` | pro.monthly、pro.annual、**max.monthly、max.annual** |
  | `max` | max.monthly、max.annual |

  **Max の 2 商品は `pro` と `max` の両方に紐づける。** 片方だけにすると、Max の人が一部の機能を使えなくなる

- [x] **Offering**（9/28） — 「Offerings」で識別子 `default` を作り（あればそれを使う）、**Current** にする。package を 4 つ

  | Package の識別子 | 商品 |
  |---|---|
  | `$rc_monthly`（Monthly を選ぶ） | pro.monthly |
  | `$rc_annual`（Annual を選ぶ） | pro.annual |
  | `max_monthly`（Custom を選ぶ） | max.monthly |
  | `max_annual`（Custom を選ぶ） | max.annual |

- [ ] **Restore behavior** — Project settings で「**Transfer to new App User ID**」（既定）のままであること
      （appUserID は端末 ID。機種変更して復元すると契約が新しい端末に移る）
- [x] **公開 SDK キーをコピー**（9/28） — 「API keys」→ App Store アプリの **Public API key**（`appl_...`）。
      **secret キー（`sk_...`）はアプリに入れない**（ゲートウェイにだけ置く。§3 で設定済み）

#### 2-3. キーをアプリに入れる

- [x] `JournalMate/AI/BillingConfig.swift` の `revenueCatAPIKey` に `appl_...` を入れてビルド（9/28・ビルド成功）
      （Claude Code に貼れば入れてビルドまで確かめる。公開前提の値なのでアプリに入れてよい）

#### 2-4. 実機で購入を試す（キーを入れた後）

- [ ] **Sandbox のテストアカウント** — App Store Connect → ユーザとアクセス → Sandbox で作る
- [ ] iPhone の **設定 → App Store → Sandbox アカウント** でサインイン
- [ ] Xcode から実機で起動して確かめる
  - [ ] プラン画面に**実際の価格**が出る
  - [ ] Pro を購入 → 画面が閉じ、設定のプランが「Pro」になる
  - [ ] 設定の「プランを変更」から Max に変えられる
  - [ ] RevenueCat の「Customers」に購入の記録が出る

作ったばかりの商品は、App Store 側に反映されるまで数十分かかることがある。
その間は価格が取れず参考価格（円）の表示になるが、故障ではない。

### 3. ゲートウェイ ― 手作業（Cloudflare）

手順と説明は [cloudflare.md](cloudflare.md)（ブログと同じアカウント・無料プランで立てる）。
**これが無いと契約しても AI が一切動かない**ので審査で落ちる。

デプロイ先: **`https://journal-mate-api.ai-swift.com`**（ai-swift.com のサブドメイン。DNS と証明書は Cloudflare が自動で作成）

- [x] KV を作り、id を `wrangler.toml` に
- [x] `wrangler.toml` の `APP_ID` を `K85V2B647P.app.journalmate.JournalMate` に（9/28・**デプロイはまだ**）
- [x] `wrangler.toml` の `routes` に `journal-mate-api.ai-swift.com`
- [x] 秘密: `ANTHROPIC_API_KEY` / `RC_SECRET_KEY`（secret キー） / `RC_WEBHOOK_SECRET` / `SESSION_SECRET`
- [x] 秘密: `APPLE_ROOT_CA_PEM`（Apple App Attestation Root CA）
- [ ] 秘密: `DEVICECHECK_KEY_P8` / `DEVICECHECK_KEY_ID` / `APPLE_TEAM_ID` ← **Apple 承認待ち**
      （**入れないと、端末を初期化するたびに無料枠もトライアルも戻る**。
      入れるまでのあいだ、ゲートウェイは DeviceCheck を飛ばして動く）
- [x] `npm test` → `npx wrangler deploy` → `curl` で `/v1/challenge`（200）と 401 を確認（9/27）
- [x] `BillingConfig.gateway` に URL を入れる
- [x] Xcode の Signing & Capabilities に **App Attest** を追加（9/28・`JournalMate/JournalMate.entitlements`、production）
- [x] RevenueCat の Webhook を `https://journal-mate-api.ai-swift.com/webhooks/revenuecat` に向け、
      Authorization ヘッダに `RC_WEBHOOK_SECRET` と同じ値（テストイベントで 200 を確認）
- [x] `ATTEST_MODE = "on"` を確認 ← **DEBUG モード中は `"off"`。提出前に必ず戻す（下の §3.1）**
- [x] Anthropic Console で**月の利用上限（Spend limit）**を設定

### 3.0 攻撃への備え（9/29 にコードは入れた。デプロイと WAF は手作業）

- [x] チャレンジを KV に保存しない（署名付き）— 連打で KV の書き込み枠（1 日 1,000 回）を尽きさせない
- [x] 回数の制限（Rate Limiting バインディング）— 認証前は IP ごと 1 分 60 回、認証後は端末 ID ごと 1 分 30 回
- [x] Anthropic に `metadata.user_id`（端末 ID のハッシュ）を付ける — 違反があってもアカウント全体を止められにくくする
- [x] 無料枠全体の上限を 1 日 200 万・月 3,000 万に下げる（無料は初回起動の 2 回だけになったため）
- [x] トライアルの出力上限 3,000（8,000 のままだと 1 回で 4 万を押さえて 429 になっていた）
- [ ] `npx wrangler deploy`
- [ ] **Cloudflare の WAF でレート制限ルールを 1 つ作る**（Worker に届く前に止める。無料プランで 1 つ作れる）
      ダッシュボード → ai-swift.com → **セキュリティ → WAF → レート制限ルール** →「ルールを作成」
      - ルール名: `journal-mate-api`
      - 条件: 「ホスト名」が `journal-mate-api.ai-swift.com` に等しい
      - 特性: IP（既定のまま）
      - 期間 10 秒あたり **30** リクエストを超えたら → アクション「ブロック」、期間 10 秒
- [ ] 後で（利用者が 1 日 1,000 人を超える前に）: 端末の鍵（`key:<keyId>`）の保存を KV から Durable Object に移す。
      セッションを取るたびに KV へ 1 回書くので、1 日のアクティブ利用者が 1,000 人を超えると KV の書き込み枠に当たる

### 3.1 DEBUG モード（シミュレータからゲートウェイを試す）

App Attest はシミュレータでは動かないので、開発中だけ**合言葉**でセッションを取る。
Apple Developer Program の承認前でも、ゲートウェイ経由の AI（無料枠・トライアル・3 つのモデル）を確かめられる。

**`"off"` のあいだは、合言葉を知っていれば誰でもセッションを取れる（＝ Anthropic の請求がこちらに来る）。**
終わったら必ず「戻す」の手順を踏む。

#### 入れる

1. 合言葉を作ってゲートウェイに入れる（画面に出た値を控える。会話やリポジトリには書かない）
   ```sh
   cd ~/Documents/Code/journal-mate/Gateway
   openssl rand -hex 24 | tee /dev/tty | npx wrangler secret put DEV_BYPASS_TOKEN
   ```
2. `Gateway/wrangler.toml` を書き換えて再デプロイ
   ```toml
   ATTEST_MODE = "off"  # 開発中のみ。提出前に必ず "on" に戻す
   ```
   ```sh
   npx wrangler deploy     # 出力の Vars に ATTEST_MODE: "off" と出れば OK
   ```
   （本番の認証を弱める操作なので、Claude Code からは実行できない。自分のターミナルで打つ）
3. Xcode の **Product > Scheme > Edit Scheme… > Run > Arguments > Environment Variables** に追加

   | Name | Value |
   |---|---|
   | `GATEWAY_DEV_BYPASS` | 1 の合言葉 |

   Edit Scheme 下の **Shared のチェックは外したまま**（入れると `.xcscheme` に合言葉が書かれてリポジトリに入る）
4. シミュレータで DEBUG ビルドを実行。ログは別のターミナルで `npx wrangler tail`

アプリがこの環境変数を読むのは **DEBUG ビルドのシミュレータ実行だけ**（`GatewaySession.devBypassToken`）。
実機と App Store のビルドにはこの経路が入らない。

#### 確かめられること / 確かめられないこと

| | シミュレータ（DEBUG モード） |
|---|---|
| チャット・ストリーミング、3 つのモデル ID | ○ |
| 無料枠 20 回 → 21 回目に Paywall、トライアルの開始と上限 | ○（サーバ側の数え方） |
| 入れ直し・端末初期化で無料枠やトライアルが戻らないこと | ✕ DeviceCheck が動かない → 実機で |
| App Attest | ✕ → 実機で |
| 購入・復元 | ✕ App Store Connect の商品が要る |

#### 戻す（提出前に必ず）

1. `Gateway/wrangler.toml` を `ATTEST_MODE = "on"` に戻して `npx wrangler deploy`（Vars に `"on"` と出ること）
2. 合言葉を消す: `npx wrangler secret delete DEV_BYPASS_TOKEN`
3. 確認: 合言葉付きでセッションを取りに行き、**400「初回は attestation が要ります」**になること
   （`"off"` のままだとセッションが返ってしまう）
   ```sh
   GW=https://journal-mate-api.ai-swift.com
   C=$(curl -s -X POST $GW/v1/challenge | sed 's/.*"challenge":"\([^"]*\)".*/\1/')
   curl -s -X POST $GW/v1/session -H 'x-dev-bypass: <合言葉>' -H 'content-type: application/json' \
     -d "{\"appUserId\":\"check\",\"keyId\":\"check\",\"challenge\":\"$C\"}"
   ```

開発用と本番用で Worker を分けたくなったら、`wrangler.toml` に `[env.dev]` を作って
`npx wrangler deploy --env dev`（cloudflare.md §7）。そのときは `BillingConfig.gateway` も DEBUG で切り替える。

### 4. ドキュメントを公開して URL を埋める ― 手作業

- [x] `docs/` を GitHub Pages（Settings > Pages > `/docs`）か Cloudflare Pages に置く
- [x] `docs/privacy.html` と `docs/index.html` の `[運営者名]` `[連絡先メール]` を埋める（9/29 確認）
- [x] `JournalMate/Features/Shared/AIConsentSection.swift` の `LegalLinks.privacy` に URL を入れる
      （**空のままだとアプリ内にポリシーのリンクが出ず 3.1.2 で落ちる**）

### 5. 実機で確かめる ― 手作業（オフラインでは確かめられないところ）

最優先（通らないと本番で全員の AI が止まる）:

- [x] **App Attest を実機で 1 回通す** — `Gateway/src/attest.ts` の Apple 証明書まわり
      （鎖の検証・nonce・keyId の導出）は実機の attestation を一度も通していない。
      通らないときは `npx wrangler tail` に `attest failed` が出る。
      時間切れになりそうなら、`ATTEST_MODE` をどうするかをそこで判断する
- [ ] **3 つのモデル ID が通るか** — `claude-haiku-4-5-20251001`（無料・トライアル）、
      `claude-sonnet-5`（Pro）、`claude-opus-5`（Max）。本物の呼び出しで 1 回ずつ
- [ ] 契約者としてチャットを 1 往復し、ストリーミングが素通しで届くこと

課金:

- [ ] Sandbox で購入・復元・解約を通す
- [ ] Sandbox で **Pro → Max のアップグレード** — Paywall が閉じ、設定のプランが Max、ログで Opus
- [ ] 解約 → Webhook → 次の呼び出しが 402 になり、Paywall が出ること

無料枠・トライアル・端末 ID:

- [ ] **トライアル後（無料プラン）** — Chat の入力欄・「Save to Journal」、Journal タブの入力欄、フォルダの Add / Edit に触れた瞬間に Paywall。Calendar・Folders の閲覧と書き出しはできること
- [ ] **無料トライアル** — 開始 → 全機能が開く・ログで Haiku・1 日 8 万（7 日合計 40 万）で止まる
- [ ] **入れ直し** — アプリを削除して入れ直し、次がすべて続きからになること（端末 ID が同じ）
  - 無料枠の残り回数、トライアル（期間中なら続く・終了済みならやり直せない）
  - 契約者は「購入を復元」→ 今月の使用量が続きから
  - AI がそのまま使えること（残った keyId で署名に失敗 → 鍵の作り直しに進む）

上限:

- [ ] `PLANS.pro.daily` を一時的に小さくして 429 → 「今日の上限」と出て**記録は続けられる**こと。
      `monthly` を小さくしたときは「今月の上限」と、Pro の人にだけ Max の案内が出ること

画面:

- [ ] シミュレータでアプリ全体を一通り動かす（§10.3 が未実施のまま。
      カレンダーの絞り込みとオンボーディングの 1 画面目だけは確認済み）。
      ゲートウェイ経由で試すなら、合言葉の手順は cloudflare.md §7

### 6. 9/27（日）まで: 審査に提出 ― 手作業

- [ ] **スクリーンショット** — 6.9 インチ（1320×2868）か 6.7 インチ（1290×2796）を最低 1 サイズ。
      Devpost 用に 1179×2556 も撮る（端末フレームなし）。シミュレータで ⌘S。仮データを入れてから撮る
- [ ] App Store Connect に説明文・キーワード・URL・カテゴリ・年齢制限・
      **App のプライバシー**を入力（答えは [submission.md](submission.md)）
- [ ] 審査メモ（App Review Information）を貼る
- [x] `MARKETING_VERSION` を `1.0` に（今は `0.1`）（9/29 確認）
- [ ] **`ATTEST_MODE = "on"` を最終確認**（`"off"` だと合言葉さえ知れば誰でもセッションを取れる）。**§3.1 の「戻す」を 3 つとも**
- [x] Product > Archive → Distribute App → App Store Connect にアップロード（9/29 ビルド 1.0 (1)）
- [ ] **課金アイテムをアプリのバージョンに紐づけて**審査に提出（初回の課金アイテムはアプリと一緒に審査される）。
      サブスクリプション側にも審査用スクリーンショット（Paywall）が要る
- [ ] 「審査通過後に自動で公開」を選ぶ
- [ ] 間に合いそうにないときは **審査の迅速化（Expedited Review）** を申請

### 7. 審査待ちの間: Devpost 提出物 ― 手作業

<a id="devpost-提出物"></a>

- [ ] アプリの機能の説明文（下書き: [submission.md](submission.md#2-devpostrevenuecat-shipaton-2026)）
- [ ] **デモ動画** — 実機で **2 分以内**、YouTube か Vimeo に公開（台本は submission.md）
- [ ] 1024×1024 のアプリアイコン（`JournalMate/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`）
- [ ] 1179×2556 のスクリーンショット（端末フレームなし）を 1 枚以上
- [ ] トライアルとオファーコードの案内（submission.md の Testing instructions）— オファーコードは公開後に発行して `XXXX` を埋める（§2）

### 8. 公開されたら

- [ ] すぐに App Store の URL を入れて Devpost で提出。**9/30 の日中（日本時間）には済ませる**

---

## 決めること

- [ ] **オンボーディングの AI ツリー生成を無料枠に入れるか** — 設計書と実装が食い違っている
  - [development.md §5.1](development.md#51-何を課金するか) は「1 インストール 1 回だけなので
    原価が固定。有料にすると活性化を殺す」として**無料のまま**と書いてあるが、
    実装は無料ユーザーに届いていない（`FREE_FEATURES` に無く、`OnboardingScreen.swift` は
    `for: nil` で呼ぶので AI 無しの経路に落ちる）。トライアル中の人には届く
  - 無料にするなら: `ProFeature` に「ツリー生成」を足して `monthlyFreeLimit` を 1、
    Gateway の `FREE_FEATURES` にも同じ名前で 1、呼び出し側で `for:` に渡す。
    **初回の体験がここで決まる**ので、無料にする側に倒すのが筋だと思う
  - 有料のままにするなら §5.1 の表から該当行を消す

---

## 公開後でよいもの

### 数値を決める（実データが出てから）

- [ ] 1 日の上限（トライアル 2 万 / Pro 8 万 / Max 16 万・重み付き）— **アプリとサーバの両方**を直す
      （`TokenBudget` と `Gateway/src/config.ts` の `PLANS` / `TRIAL`）
- [ ] 月の上限（Pro 60 万 / Max 120 万。手取りの 30% / 40% を原価に充てた値）。
      変えたらゲートウェイのテストが採算を確かめる
- [ ] `MAX_TOKENS_CAP`（現在 8,000）と `estimateReserve` の見積もりの粗さ
- [ ] 無料枠の `FREE_POOL_DAILY` / `FREE_POOL_MONTHLY`（全体の天井）と
      `FREE_MAX_TOKENS`（現在 2,000）。無料の抽出が途中で切れないかを見て決める

### 直しておきたいところ（動くが粗い）

- [ ] **401 を受けたときのトークン再取得** — `GatewaySession` は期限切れを先回りして取り直すが、
      サーバの都合で 401 が返ったときに 1 回だけ取り直して再送する経路が無い
- [ ] **`x-budget-*` ヘッダをアプリが読んでいない** — アプリは自分が数えた `token_usage` しか見ていない。
      ヘッダで上書きするのが正しい
- [ ] **ゲートウェイの 1 日の上限の 429** — 月・トライアルの合計は専用の文言にしたが、
      日次の 429 はまだ一律「レート制限」と出る（アプリの事前停止で普段は当たらない）
- [ ] **端末トークンを毎回取っている** — `DCDevice.generateToken()` は無料枠・トライアルの**初回**しか
      使われないのに、無料の呼び出しごとに取って送っている。呼び出しのたびに数十 ms 増える
- [ ] Worker のログ・アラート（上限に当たり続けている人、無料枠の共有プールが天井に近いこと）
- [ ] **無期限に残るデータの掃除** — KV の `key:<keyId>` と各台帳は、使われなくなった端末のぶんも残る。
      プライバシーポリシーで保存期間を明記するなら、一定期間使われていないものを消す処理が要る
- [ ] **無料プランの KV 書き込み（1 日 1,000 回）** — 使う人が数百人規模になったら
      Workers Paid（月 $5）へ（cloudflare.md §9）

### 課金と関係ない未決事項

- [ ] iCloud 同期（CloudKit で SQLite ごとか、レコード単位か）
- [ ] 画像添付 UI

---

## 済んだこと

### 2026-09-27（Claude Code）

- [x] **プラン画面**（`Billing/PlanChooser.swift`）— 7 日間無料トライアル / Pro / Max をカードで並べ、
      月額 / 年額の切り替え付き。オンボーディングの最後と設定の「プランを変更」の両方で使う。
      課金が未設定でも説明と価格（参考価格）は出し、購入ボタンだけ止める
- [x] RevenueCat SDK（`purchases-ios` 5.91.0）を追加し、購入・復元のコードを初めてビルド

### 2026-09-26（Claude Code）

- [x] **価格とプラン** — 無料 → トライアル（7 日・Haiku・無料）→ Pro（Sonnet・¥770 / ¥7,700）→
      Max（Opus・¥2,980 / ¥29,800）。上限は価格から逆算（development.md §5 のまとめ・§5.6〜5.8）
- [x] **Max プラン** — ゲートウェイがプランを見てモデルと上限を強制。Paywall・設定のアップグレード導線
- [x] **アプリ内の無料トライアル** — `POST /v1/trial/start`、1 端末 1 回（DeviceCheck bit1）、
      7 日間の合計は台帳の全期間の合計で数える（月をまたいでも戻らない）
- [x] **主キーを端末 ID に統一** — Keychain の「この端末限定」の UUID。RevenueCat の appUserID も同じ。
      入れ直しで使用量が白紙に戻る抜け穴と、入れ直し後に AI が使えなくなる不具合を解消（§5.9）
- [x] 月の上限・トライアルの合計の 429 を専用の文言に（Max の人には Max を案内しない）
- [x] 購読状態のキャッシュを 1 時間に（アプリの申告 `X-Plan` と食い違えば聞き直す）
- [x] シミュレータからゲートウェイを試す合言葉の経路（DEBUG のシミュレータ実行だけ）
- [x] [cloudflare.md](cloudflare.md) — Cloudflare でやることを説明付きで
- [x] プライバシーポリシーを端末 ID に合わせて更新（アプリ削除後も Keychain に残りうることを明記）

### 2026-09-25（Claude Code）

- [x] **プライバシーポリシー** `docs/privacy.html`（日英）と**サポートページ** `docs/index.html`
- [x] **AI へのデータ送信の同意**（App Review 5.1.2(i)）— 既定オフ。オフのあいだはどこからも送信しない
- [x] **Paywall に規約とポリシーへのリンク、自動更新の説明文**（App Review 3.1.2）
- [x] **プライバシーマニフェスト** `PrivacyInfo.xcprivacy`
- [x] **輸出コンプライアンス** — `ITSAppUsesNonExemptEncryption = NO`
- [x] **アプリアイコン 1024×1024**
- [x] **App Store の説明文・キーワード・審査メモ・プライバシーラベルの答え・Devpost の文面・
      デモ動画の台本** — [submission.md](submission.md)

### それ以前

- [x] 無料ユーザーの「月 20 回」をゲートウェイ経由で届ける（2026-09-24）。サーバが回数を数え、
      無料の呼び出しは Haiku に固定、無料枠全体の出費にも天井
