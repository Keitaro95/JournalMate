# 提出用の文面（App Store Connect / Devpost）

最終更新: 2026-09-25

コピペ用の下書き。`[ ]` の箇所は決まったら埋める。
締め切りと段取りは [todo.md](todo.md) の冒頭に。

---

## 1. App Store Connect

### 名前・サブタイトル

| 項目 | 上限 | 案 |
|---|---|---|
| 名前 | 30 字 | `JournalMate` — 取られていたら `JournalMate: AI ジャーナル` |
| サブタイトル（日本語） | 30 字 | `話すだけで、日記が勝手に整理される` |
| サブタイトル（英語） | 30 字 | `Talk it out. It files itself.` |
| カテゴリ | | プライマリ: 仕事効率化 / セカンダリ: ライフスタイル |
| 年齢制限 | | 4+（ユーザー生成の文章は端末内のみ・他人と共有しない） |

### キーワード（100 字・カンマ区切り・スペースなし）

```
ジャーナル,ジャーナリング,AI,メモ,PARA,振り返り,習慣,ライフログ,思考整理,Markdown,チャット,自己分析,目標,マインドフルネス,セルフケア,手帳
```

- 83 字。`Obsidian` は他社の商標なので入れない（ガイドライン 2.3.7）
- `日記` と `整理` はサブタイトルに入っていて検索対象になるので、重ねない

### プロモーション用テキスト（170 字）

```
AI と話すだけで、その日のジャーナルができあがる。ふだんの日記は Journal へ、テーマのある記録は PARA（Projects / Areas / Resources / Archives）へ、自動で振り分けられます。
```

### 説明文（日本語）

アプリの今の動き（`JournalMate/Core/Usage.swift` の `ProFeature`）に合わせてある。
プランなしでも「書く・見返す・書き出す・取り込む」はずっと無料。AI だけがトライアルか Pro / Max。

```
話したことが、その日のジャーナルになる。
JournalMate は、AI との対話をそのまま日々の記録に変え、あとから見返せる形に自動で整理していくジャーナルアプリです。

■ 話すだけで記録になる
今日あったこと、考えていることを AI に話しかけるだけ。会話の中から、その日その時のジャーナルを AI が書き起こします。AI を使わず、自分の言葉で直接書くこともできます。

■ Journal と PARA で勝手に整理される
特定のテーマに結びつかない日々の出来事や気分は、分類せずに「Journal」へ。
テーマのある記録は Tiago Forte の PARA 手法で分類されます。
・Journal … ふつうのジャーナル（分類しない日々の記録）
・Projects … 期限のある目標
・Areas … 続けて取り組みたいこと
・Resources … 興味・学びたいこと
・Archives … 終わったこと
その下に「生活 / 旅行 / 保険」のような自分だけの階層を作れます。初期設定で AI と話せば、最初のフォルダ構造も提案してくれます。

■ 原本・教訓・日記の 3 層
各フォルダは raw（集めた情報の原本）/ knowledge（そこから導いた教訓）/ journal（その日の記録）の 3 層に分かれます。原本を書き換えないので、分類はあとからいくらでも動かせます。

■ カレンダーとツリーで見返す
カレンダーで日付を選べばその日のジャーナルが、ツリーで辿ればテーマごとの記録が見られます。

■ データはあなたの端末に
記録は端末内だけに保存されます。AI の機能を使うときだけ、同意のうえで文章を送ります。
すべての記録は、フォルダ階層ごと Markdown（Obsidian 互換）で書き出せます。ロックインはありません。

■ 7 日間の無料トライアル
・支払いの登録なしで、すべての機能を 7 日間お試しいただけます（AI は Claude Haiku）
・自動で課金されることはありません

■ プランが無くても、ずっと無料でできること
・自分の言葉でジャーナルやノートを書く・直す
・これまでのジャーナルをカレンダーとフォルダで見返す
・Markdown（Obsidian 互換）での書き出し、バックアップからの復元
・メモ.app や Obsidian からのメモの取り込み
・AI の機能には Pro か Max（またはトライアル）が必要です

■ Pro でできること（Claude Sonnet）
・AI とのチャット
・AI でのジャーナル書き起こしと、PARA への自動振り分け
・過去のジャーナルから引き出す：AI が過去の記録を踏まえて語りかけ、「あの時どうしてたっけ」「どうしよう」と迷ったときに過去の自分から答えを引き出します
・自分の傾向：集めた原本とジャーナルから、いまの傾向と向かうべき道を AI が書き出します
※ 1 日・1 か月あたりの AI の利用量に上限があります

■ Max でできること（Claude Opus）
・Pro のすべての機能を、最上位モデル Claude Opus で
・AI の利用量の上限は Pro の 2 倍

【サブスクリプションについて】
・Pro と Max は自動更新のサブスクリプションです（それぞれ月額 / 年額）。
・Pro 月額 770 円 / 年額 7,700 円
・Max 月額 2,980 円 / 年額 29,800 円
・購入の確認時に Apple ID へ請求されます。
・期間終了の 24 時間前までに自動更新をオフにしない限り、自動的に更新されます。
・購入後は App Store のアカウント設定から管理・解約できます。
・アプリ内の 7 日間の無料トライアルは支払いの登録が不要で、自動で課金されることはありません。

利用規約（EULA）: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
プライバシーポリシー: [プライバシーポリシーの URL]
```

### 説明文（英語）

英語のストアでは価格が各国の価格帯で変わるので、金額は書かない（App Store が表示する）。

```
What you say becomes that day's journal.
JournalMate turns your conversations with AI into a daily record, and organizes it automatically so you can look back on it later.

■ JUST TALK, AND IT'S RECORDED
Tell the AI what happened today or what's on your mind. From the conversation, the AI writes up a journal entry for that day and moment. You can also write entries in your own words, without AI.

■ ORGANIZED FOR YOU WITH JOURNAL AND PARA
Everyday events and moods that don't belong to a particular theme go into "Journal", unsorted.
Entries with a theme are sorted using Tiago Forte's PARA method.
• Journal: your everyday journal (unsorted daily records)
• Projects: goals with a deadline
• Areas: things you keep working on
• Resources: interests and things you want to learn
• Archives: things that are finished
Under each, you can build your own hierarchy, like "Life / Travel / Insurance". Talk to the AI during setup and it suggests your first folder structure.

■ THREE LAYERS: SOURCES, LESSONS, JOURNAL
Each folder has three layers: raw (the original information you collect), knowledge (the lessons you draw from it), and journal (what happened each day). Originals are never rewritten, so you can reorganize as often as you like.

■ LOOK BACK BY CALENDAR OR TREE
Pick a date on the calendar to see that day's journal, or follow the tree to see records by theme.

■ YOUR DATA STAYS ON YOUR DEVICE
Your records are stored only on your device. Text is sent to the AI only when you use an AI feature, and only with your consent.
You can export everything, folder hierarchy included, as Markdown (Obsidian-compatible). No lock-in.

■ 7-DAY FREE TRIAL
• Try every feature for 7 days with no payment details required (AI powered by Claude Haiku)
• You will never be charged automatically

■ FREE FOREVER, NO PLAN NEEDED
• Write and edit journals and notes in your own words
• Look back on your past journals in Calendar and Folders
• Export as Markdown (Obsidian-compatible) and restore from backups
• Import memos from the Notes app or Obsidian
• AI features require Pro or Max (or the free trial)

■ PRO (CLAUDE SONNET)
• Conversations with AI
• AI journal extraction, automatically filed into PARA
• Draw on your past journals: the AI talks with you with your past records in mind, and when you wonder "What did I do last time?" or "What should I do?", it brings back answers from your past self
• Your patterns: the AI blends your collected sources and journals, and writes out your current patterns and the direction to head in
* There are daily and monthly limits on AI usage

■ MAX (CLAUDE OPUS)
• Everything in Pro, with Claude Opus, the most capable model
• Twice the AI usage limits of Pro

ABOUT SUBSCRIPTIONS
• Pro and Max are auto-renewable subscriptions, each available monthly or yearly.
• Payment is charged to your Apple ID at confirmation of purchase.
• Your subscription renews automatically unless auto-renew is turned off at least 24 hours before the end of the current period.
• You can manage and cancel your subscription in your App Store account settings after purchase.
• The 7-day in-app free trial requires no payment details and never results in an automatic charge.

Terms of Use (EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
Privacy Policy: [Privacy Policy URL]
```

### URL

| 項目 | 値 |
|---|---|
| プライバシーポリシー URL | `[公開先]/privacy.html`（`docs/privacy.html`） |
| サポート URL | `[公開先]/`（`docs/index.html`） |
| マーケティング URL | 空欄でよい |

### App のプライバシー（「栄養ラベル」）の答え

`JournalMate/Resources/PrivacyInfo.xcprivacy` と揃えてある。

- **データの収集: はい**
- トラッキング: **なし**（全項目「トラッキングに使用しない」）
- 全項目「ユーザーに紐付けない」、目的は「App の機能」のみ

| 種類 | 項目 | 理由 |
|---|---|---|
| ユーザーコンテンツ | その他のユーザーコンテンツ | AI 機能で送る文章（Anthropic へ） |
| ID | ユーザー ID | 端末 ID（アプリが作る乱数。RevenueCat の appUserID に使う） |
| ID | デバイス ID | 端末 ID / App Attest の keyId / DeviceCheck |
| 購入 | 購入履歴 | RevenueCat |

### 輸出コンプライアンス

`ITSAppUsesNonExemptEncryption = NO` をビルド設定に入れてある（HTTPS のみ）。
アップロード後に質問は出ないはず。出たら「いいえ（免除対象の暗号化のみ）」。

### 審査メモ（App Review Information > Notes）

App Store Connect の審査メモ欄にそのまま貼る。見出し 1〜6 は Apple が求める項目の順。
英語版と日本語版は同じ内容（欄の上限は 4,000 字。英語版は約 3,500 字、日本語版は約 2,900 字）。どちらか一方を貼る。UI のラベルは英語（日本語 UI での表記）の形で書いてある。

#### 英語

```
Thank you for reviewing JournalMate.

1. PURPOSE AND TARGET USERS
For people who want to keep a journal but find daily writing and organizing hard. You talk to an AI about your day; the app turns the conversation into a dated journal entry and files it: everyday entries into "Journal", topic entries into a PARA hierarchy (Projects / Areas / Resources / Archives, Tiago Forte's method) with the user's own sub-folders. Look back by date (Calendar tab) or theme (Folders tab). Pro's "past recall" lets the AI answer using the user's own past journals. Entries can also be written by hand. All data stays on the device and can be exported as Markdown.

2. SETUP AND ACCESS
- No account, login or sample files needed.
- First launch: onboarding explains the app, asks for AI consent, offers one free AI conversation, then shows "Choose Your Plan" (プランを選ぶ). Tap "Continue for Free" (無料で始める) or start the trial.
- AI consent (Guideline 5.1.2(i)): AI features send the relevant text to Anthropic's Claude API. OFF by default. Turn on in onboarding or Settings > "Sending Data to AI" (AI へのデータ送信). While off, no text leaves the device.
- Free trial, no purchase: Settings > "Change Plan" (プランを変更) > "7-Day Free Trial" (7 日間の無料トライアル). Unlocks everything for 7 days, no payment details, never converts to paid. Once per device.
- Features:
  - Chat tab: talk to the AI, tap the record button to make a journal entry.
  - Journal tab (ジャーナル): write by hand (trial / Pro / Max).
  - Calendar tab (カレンダー): entries by date.
  - Folders tab (フォルダ): Journal + PARA > folders > raw / knowledge / journal.
  - Settings > "Import Memos" (外部からメモを登録): import from Notes or Obsidian; any .txt / .md file in Files works.
  - Settings > "Export Backup (.zip)" (バックアップを書き出す): export as Markdown.

3. EXTERNAL SERVICES
- Anthropic Claude API (AI): chat, journal extraction, past recall. Claude Haiku (onboarding / trial), Sonnet (Pro), Opus (Max). Sent only with consent.
- Our relay on Cloudflare Workers (journal-mate-api.ai-swift.com): forwards AI requests so no API key ships in the app; enforces usage limits; stores no journal content.
- RevenueCat (on Apple IAP): purchases, restore, server-side entitlement checks.
- Apple App Attest / DeviceCheck: verify the genuine app; bind the trial to the device.
No login, analytics, ads or tracking SDKs.

4. REGIONS
Works the same in all regions. UI in Japanese or English per device language. Prices follow each storefront's tier.

5. REGULATED INDUSTRY / THIRD-PARTY MATERIAL
Not applicable: not a regulated service (medical, financial, health) and no protected third-party content. "Obsidian" is named only for Markdown compatibility; no affiliation.

6. IN-APP PURCHASES
Auto-renewable subscriptions, one group:
- Pro Monthly / Annual (app.journalmate.pro.monthly / .pro.annual): writing journals, AI chat, AI journal extraction, past recall, "Your patterns". Claude Sonnet, daily and monthly usage limits.
- Max Monthly / Annual (app.journalmate.max.monthly / .max.annual): everything in Pro with Claude Opus, twice Pro's limits.
Free without purchase: viewing past journals, import, export, backup restore, plus one AI conversation and one extraction in onboarding. Writing and AI need the trial, Pro or Max.
Purchase flow: Settings > "Change Plan" (プランを変更), or use a Pro feature without a plan (send a chat message, or open the Journal tab) to open the paywall. Both have "Restore Purchases" (購入を復元). Testable in the sandbox.
```

#### 日本語

```
JournalMate をご確認いただきありがとうございます。

1. アプリの目的と対象ユーザー
JournalMate は、日記を続けたいけれど、毎日書くことや書いたものの整理が負担になっている人のためのジャーナルアプリです。その日のことを AI に話すと、会話から日付つきのジャーナルを書き起こし、自動で振り分けます。特定のテーマに結びつかない日々の記録は「Journal」へ、テーマのある記録は PARA（Projects / Areas / Resources / Archives。Tiago Forte によるノート整理の手法）の階層と、ユーザーが作ったサブフォルダへ入ります。記録は日付（カレンダータブ）でもテーマ（フォルダタブ）でも見返せます。Pro の「過去のジャーナルから引き出す」機能では、AI がユーザー自身の過去の記録を踏まえて質問に答えます。AI を使わずに自分で書くこともできます。記録はすべて端末内だけに保存され、いつでも Markdown で書き出せます。

2. セットアップと主要機能へのアクセス方法
- アカウント、ログイン、認証情報は不要です。サンプルファイルも不要です。
- 初回起動時のオンボーディングで、アプリの説明、AI へのテキスト送信の同意、AI との会話の 1 回お試しを行い、最後にプラン選択画面（「プランを選ぶ」/ Choose Your Plan）が表示されます。「無料で始める」（Continue for Free）を押すか、トライアルを開始してください。
- AI へのデータ送信の同意（ガイドライン 5.1.2(i)）：AI の機能は、関連するテキストを Anthropic の Claude API に送信します。初期状態はオフです。オンボーディング中、または 設定 >「AI へのデータ送信」（Sending Data to AI）>「AI の機能のために内容を送信する」（Send Content for AI Features）でオンにできます。オフの間は、テキストが端末の外に出ることはありません。
- 購入せずにすべての AI 機能を使うには：設定 >「プランを変更」（Change Plan）>「7 日間の無料トライアル」（7-Day Free Trial）。支払い情報の登録は不要で、有料のサブスクリプションに切り替わることはありません。1 端末につき 1 回です。
- 各機能の場所：
  - チャットタブ：AI と話し、記録ボタンを押すと会話がジャーナルになります。
  - ジャーナルタブ：AI を使わずに自分で書けます（トライアル / Pro / Max）。
  - カレンダータブ：日付を選ぶと、その日の記録が表示されます。
  - フォルダタブ：Journal と PARA > 自分のフォルダ > raw / knowledge / journal。
  - 設定 >「外部からメモを登録」（Import Memos）：メモ.app や Obsidian から取り込めます。ファイル App にある任意の .txt / .md ファイルで試せます。
  - 設定 >「バックアップを書き出す（.zip）」（Export Backup (.zip)）：すべての記録を Markdown で書き出します。

3. 使用している外部サービス
- Anthropic Claude API（AI サービス）：会話、ジャーナルの書き起こし、過去のジャーナルからの引き出し。モデルは Claude Haiku（オンボーディングのお試し / トライアル）、Claude Sonnet（Pro）、Claude Opus（Max）です。テキストはユーザーが同意した場合にのみ送信されます。
- 自社の中継サーバ（Cloudflare Workers、journal-mate-api.ai-swift.com）：アプリに API キーを入れないよう、AI へのリクエストを Anthropic へ中継し、利用量の上限を管理します。ジャーナルの内容は保存しません。
- RevenueCat（Apple の App 内課金の上に載せたサブスクリプション管理）：購入、復元、サーバ側での購読状態の確認。
- Apple App Attest / DeviceCheck：リクエストが正規のアプリからのものであることの確認と、無料トライアルを端末に紐づけるために使用します。
ログインサービス、解析、広告、トラッキングの SDK は使用していません。

4. 地域による違い
提供しているすべての地域で同じように機能します。UI は端末の言語設定に応じて日本語または英語で表示されます。サブスクリプションの価格は各ストアの App Store 価格帯に従います。地域によって異なるコンテンツや機能はありません。

5. 規制業種・第三者の保護された素材
該当しません。規制の厳しい業種（医療、金融、ヘルスケアなど）のサービスではなく、保護された第三者の素材も含みません。「Obsidian」はファイル形式の互換性（プレーンな Markdown）を説明するためにのみ記載しており、同社との提携関係はありません。

6. App 内課金
1 つのサブスクリプショングループに、自動更新サブスクリプションがあります。
- Pro 月額（app.journalmate.pro.monthly）/ Pro 年額（app.journalmate.pro.annual）：AI とのチャット、AI でのジャーナル書き起こし、過去のジャーナルから引き出す、自分の傾向。Claude Sonnet を使用し、1 日・1 か月あたりの利用量に上限があります。
- Max 月額（app.journalmate.max.monthly）/ Max 年額（app.journalmate.max.annual）：Pro のすべての機能を Claude Opus で。利用量の上限は Pro の 2 倍です。
購入なしで使えるもの：ジャーナルを書く・直す、カレンダーとフォルダでの閲覧、取り込み、書き出し、バックアップからの復元。オンボーディングでは、AI との会話と AI での書き起こしを 1 回ずつ無料で試せます。AI の機能には、トライアル、Pro、Max のいずれかが必要です。
購入画面への行き方：
- 設定 >「プランを変更」（Change Plan）、または
- プランなしで Pro の機能を使う（例：チャットタブでメッセージを送る、ジャーナルタブを開く）と Paywall が開きます。
どちらの画面にも「購入を復元」（Restore Purchases）があります。購入はサンドボックスで試せます。
```

---

## 2. Devpost（RevenueCat Shipaton 2026）

提出物のチェックリストは [todo.md](todo.md#devpost-提出物)。

### Tagline

```
Talk to an AI about your day — it writes the journal and files it into PARA for you.
```

### What it does

```
JournalMate turns a conversation into a journal. You talk to Claude about your day; the app extracts a dated journal entry and files it — everyday entries into a plain Journal, topic-specific ones into a PARA hierarchy (Projects / Areas / Resources / Archives) with your own sub-folders like Life > Travel > Insurance. Every folder has three layers borrowed from the data-engineering "medallion" pattern: raw (sources, never rewritten), knowledge (lessons you draw from raw + journals), and journal (what happened, when). Because originals are never modified, you can reorganize freely.

Look back by date on the Calendar tab, or by theme on the Tree tab. Weekly and monthly reviews summarize what you did and what you learned. Everything lives in a single on-device SQLite file, and you can export the whole vault as Obsidian-compatible Markdown at any time.
```

### How we built it

```
- SwiftUI, iOS 18, Swift 6. No third-party dependencies except RevenueCat.
- Storage: a ~200-line libsqlite3 wrapper with FTS5 (trigram tokenizer so Japanese search works). Folders are virtual; PARA codes like "3152" are materialized so a subtree is one prefix query.
- AI: Claude via the Messages API (streaming chat + strict tool use for structured extraction).
- Monetization with RevenueCat: "pro" and "max" entitlements, monthly + yearly for each; the paywall shows exactly which feature you hit. A 7-day in-app trial (no payment) unlocks everything; afterward the app is read-only (view + export) until you subscribe.
- A Cloudflare Workers gateway so no Anthropic key ships in the app: App Attest proves the call is from the genuine app, RevenueCat's REST API + webhooks confirm the subscription, a Durable Object per user enforces daily/monthly token budgets, and DeviceCheck ties the trial to the device so reinstalling doesn't reset it.
```

### RevenueCat の使い方（審査で見られる点）

```
- purchases-ios 5.x, Purchases.configure(withAPIKey:) at launch.
- Entitlement "pro", Offering "default" with monthly and yearly packages.
- CustomerInfo drives the in-app entitlement; the gateway re-checks the entitlement server-side via the RevenueCat REST API and keeps it fresh with webhooks (cancellation / expiration → the next AI call returns 402 → paywall).
- Restore purchases in Settings and on the paywall.
```

### Challenges / What's next

```
Challenges: making the trial generous without shipping an API key; stopping reinstall abuse (App Attest identifies the app, not the device — DeviceCheck's two persistent bits solved it); Japanese full-text search in SQLite.

Next: iCloud sync, image attachments, and cheaper model routing (Haiku for classification, Opus for reviews).
```

### Testing instructions for judges

```
Download from the App Store: [App Store URL]
Settings > "Pro でできることを見る" > "7 日間の無料トライアル" unlocks every AI feature for 7 days with no purchase (Claude Haiku).
To try the paid plans: Pro offer code XXXX / Max offer code XXXX (redeem in App Store > account > Redeem Gift Card or Code).
Turn on "AI へのデータ送信" (AI data sharing) during onboarding or in Settings to enable the AI features.
```

### デモ動画（2 分以内）の台本

| 秒 | 画面 | 言うこと |
|---|---|---|
| 0–10 | アイコン → 起動 | 「話すだけで日記になり、勝手に整理されるジャーナル」 |
| 10–30 | オンボーディングの 3 つの問い → AI がフォルダを提案 | PARA の説明を一言 |
| 30–60 | Chat で今日のことを話す → 記録ボタン → 下書き → 保存 | ここが本体 |
| 60–75 | Calendar で今日を選ぶ → PARA タグ付きのジャーナル | |
| 75–90 | Tree で 生活 > 旅行 > journal を辿る | |
| 90–110 | 無料枠の残り表示 → Paywall（トライアル / Pro / Max）→ 購入 | 収益化の見せ場 |
| 110–120 | バックアップ書き出し → Obsidian で開く | 「ロックインしない」で締め |
