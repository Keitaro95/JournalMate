# Cloudflare でやること（課金用ゲートウェイ）

最終更新: 2026-09-26

ブログで使っている Cloudflare アカウント（無料プラン）に、課金用の中継サーバ
`Gateway/`（Cloudflare Worker）を**同じアカウントで追加**する手順。ブログには影響しない。

コードの設計は [Gateway/README.md](Gateway/README.md) と [development.md §5](development.md#5-課金)。
ここは「Cloudflare の画面とコマンドで何をするか」だけをまとめる。

---

## 0. 全体像 — なぜ Cloudflare に置くのか

```
iPhone アプリ ──▶ api.<自分のドメイン>（Worker）──▶ api.anthropic.com
                    │ ① 本物のアプリか      App Attest
                    │ ② 契約・トライアル・無料枠のどれか   RevenueCat / 台帳 / DeviceCheck
                    │ ③ 上限の内か          Durable Object の台帳
                    │ ④ モデルを上書き      無料・トライアル=Haiku / Pro=Sonnet / Max=Opus
```

**Anthropic の API キーをアプリに入れないために、この中継が要る。**
アプリに埋めるとバイナリから抜かれ、請求はこちらに来る。キーは Worker の秘密（secret）にだけ置く。

このゲートウェイが**無いと、契約しても AI が一切動かない**（審査で落ちる）。

Cloudflare に作られるもの:

| もの | 何に使うか | 無料プランで使えるか |
|---|---|---|
| **Worker** `journalmate-gateway` | 中継サーバ本体 | ○ |
| **Durable Object** `BudgetLedger` | 1 人 1 個の台帳（使用量・無料枠の回数・トライアルの開始時刻） | ○（**SQLite 版のみ**。`wrangler.toml` は対応済み） |
| **KV** `CACHE` | チャレンジ・端末の鍵・購読状態のキャッシュ | ○ |
| **カスタムドメイン** `api.<自分のドメイン>` | アプリが呼ぶ URL | ○（DNS と証明書は自動） |

---

## 1. 準備（1 回だけ）

```sh
cd Gateway
npm install
npx wrangler login        # ブラウザが開く。ブログと同じ Cloudflare アカウントでログイン
npx wrangler whoami       # アカウント名と ID が出れば OK
```

手元に用意しておくもの:

| もの | どこで手に入るか |
|---|---|
| Apple の **Team ID** | Apple Developer > Membership |
| Anthropic の **API キー**（`sk-ant-...`） | console.anthropic.com > API Keys |
| RevenueCat の **secret キー**（V1、`sk_...`） | RevenueCat > Project settings > API keys。**アプリに入れる公開キー（`appl_...`）とは別物** |
| DeviceCheck 用の鍵（`.p8`）と Key ID | App Store Connect > Users and Access > Integrations > Keys（DeviceCheck にチェック） |

---

## 2. `wrangler.toml` を埋める

`Gateway/wrangler.toml` の 3 か所。

### 2.1 KV を作って id を入れる

```sh
npx wrangler kv namespace create CACHE
```

出てきた `id = "..."` を `REPLACE_WITH_KV_ID` に入れる。

### 2.2 `APP_ID` を入れる

```toml
APP_ID = "<TeamID>.app.journalmate.JournalMate"
```

App Attest の検証で「このアプリからの呼び出しか」を突き合わせる値。
Bundle ID はプロジェクトの `PRODUCT_BUNDLE_IDENTIFIER`（`app.journalmate.JournalMate`）。

### 2.3 サブドメインを割り当てる

```toml
routes = [
  { pattern = "api.example.com", custom_domain = true }
]
```

`example.com` を自分のドメインに置き換える。ブログのドメインのサブドメインにしておくと:

- DNS レコードと SSL 証明書は、デプロイ時に Cloudflare が自動で作る（手で DNS を触らない）
- 後で Cloudflare から移っても、アプリに入れた URL を変えずに済む

割り当てなければ `https://journalmate-gateway.<アカウント名>.workers.dev` で動く。

---

## 3. 秘密（secret）を入れる

**秘密は `wrangler.toml` にもリポジトリにも書かない。** Cloudflare 側に暗号化して保存される。
コマンドを打つと値の入力を求められる。

```sh
# Anthropic への中継に使う。これが漏れると請求がこちらに来る
npx wrangler secret put ANTHROPIC_API_KEY

# 購読状態を RevenueCat に問い合わせる（secret キー。公開キーではない）
npx wrangler secret put RC_SECRET_KEY

# RevenueCat の Webhook が本物かを見分ける合言葉。任意の長い文字列（§6 で RevenueCat 側にも同じ値）
npx wrangler secret put RC_WEBHOOK_SECRET

# セッション JWT の署名鍵。下のコマンドで作った値を貼る
openssl rand -base64 48
npx wrangler secret put SESSION_SECRET
```

### 3.1 Apple App Attest のルート CA

[Apple の配布ページ](https://www.apple.com/certificateauthority/) から
**Apple App Attestation Root CA** の PEM を落とし:

```sh
npx wrangler secret put APPLE_ROOT_CA_PEM < Apple_App_Attestation_Root_CA.pem
```

「本物の iPhone で動く本物のアプリ」であることを確かめる証明書の根っこ。

### 3.2 DeviceCheck の鍵

```sh
npx wrangler secret put DEVICECHECK_KEY_P8 < AuthKey_XXXXXXXXXX.p8
npx wrangler secret put DEVICECHECK_KEY_ID      # 鍵の Key ID
npx wrangler secret put APPLE_TEAM_ID           # Team ID
```

DeviceCheck は、端末ごとの 2 ビットを **Apple 側に**置く仕組み。アプリを消しても残る。

- bit0 … 今月の無料枠を始めた
- bit1 … 無料トライアルを使った

アプリの入れ直しは端末 ID（Keychain に残る）で塞いでいるが、**端末を初期化すると端末 ID も消える**。
そこまで塞げるのはこのビットだけ。**入れないと、端末を初期化するたびに無料枠もトライアルも戻る。**

入れた秘密の一覧は `npx wrangler secret list` で見られる（値は見えない）。

---

## 4. デプロイ

```sh
npm test               # 70 項目が通ること
npm run typecheck
npx wrangler deploy
```

最後に `https://api.example.com`（または workers.dev の URL）が表示されれば成功。
初回はカスタムドメインの証明書の発行に数分かかることがある。

### 4.1 動いているかを確かめる

```sh
# チャレンジが返れば、Worker と KV が動いている
curl -X POST https://api.example.com/v1/challenge

# セッション無しで呼ぶと 401 になれば、認証が効いている
curl -X POST https://api.example.com/v1/messages -d '{}'
```

---

## 5. アプリに URL を入れる

`JournalMate/AI/BillingConfig.swift`:

```swift
private static let gateway = "https://api.example.com"
```

空のままだと、アプリは BYO キーの人しか AI を使えない（契約者もトライアルも無料枠も動かない）。

Xcode の Signing & Capabilities に **App Attest** を足すのも忘れずに。

---

## 6. RevenueCat の Webhook を向ける

RevenueCat > Project settings > Integrations > Webhooks:

| 項目 | 値 |
|---|---|
| Webhook URL | `https://api.example.com/webhooks/revenuecat` |
| Authorization header value | §3 の `RC_WEBHOOK_SECRET` と**同じ文字列** |

解約・失効・Pro → Max の変更がすぐゲートウェイに届く。
購読状態のキャッシュは 1 時間持つので、**Webhook が無いと解約後も最大 1 時間使えてしまう**。

購入・アップグレードの直後は Webhook が無くても困らない。アプリが `X-Plan` で「いま契約中」と
申告し、キャッシュと食い違えばゲートウェイが RevenueCat に聞き直す（1 分に 1 回まで）。

---

## 7. リリース前に必ず確かめること

- [ ] `wrangler.toml` の **`ATTEST_MODE = "on"`**（`"off"` だと合言葉さえ知れば誰でもセッションを取れる）
- [ ] 実機で 1 回 AI を呼び、`npx wrangler tail` に `attest failed` が出ないこと
      （Apple の証明書まわりは、実機の attestation をまだ一度も通していない）
- [ ] Anthropic Console で**月の利用上限（Spend limit）**を設定しておく。
      ゲートウェイの上限が万一すり抜けても、請求の天井になる

### シミュレータで試すとき（開発専用）

App Attest はシミュレータでは動かないので、開発中だけ**合言葉**でセッションを取る。

1. 合言葉を作ってゲートウェイに入れる
   ```sh
   openssl rand -base64 24
   npx wrangler secret put DEV_BYPASS_TOKEN
   ```
2. `wrangler.toml` の `ATTEST_MODE` を `"off"` にして `npx wrangler deploy`
3. Xcode の **Product > Scheme > Edit Scheme > Run > Arguments > Environment Variables** に
   `GATEWAY_DEV_BYPASS` ＝ 同じ合言葉 を足す
4. シミュレータで実行する

アプリは **DEBUG ビルドのシミュレータ実行でだけ**この環境変数を読む
（`GatewaySession.devBypassToken`）。実機と App Store のビルドにはこの経路が入らない。
合言葉はソースにもリポジトリにも書かない。

シミュレータでは DeviceCheck も動かないので、入れ直しで無料枠やトライアルが戻らないことは確かめられない
（そこは実機で）。

**`"off"` のままリリースしない。** 終わったら `"on"` に戻して `npx wrangler deploy`。
`"off"` のあいだは、合言葉を知っていれば誰でもセッションを取れる。
開発用と本番用で Worker を分けたいときは、`wrangler.toml` に `[env.dev]` を作って
`npx wrangler deploy --env dev` にする（名前が `journalmate-gateway-dev` になり、KV・秘密も別になる）。

---

## 8. 動かし始めてから

### ログと数字を見る

```sh
npx wrangler tail                 # リアルタイムのログ（attest failed / free call など）
```

Cloudflare のダッシュボード > Workers & Pages > `journalmate-gateway` で、
リクエスト数・エラー率・CPU 時間が見られる。

### 秘密を差し替える

同じ `npx wrangler secret put <名前>` をもう一度打てば上書き。デプロイし直す必要はない。

---

## 9. 無料プランの上限と、有料にする目安

Cloudflare 公式ドキュメントで確認した無料プランの上限（2026-09-26 時点）:

| 項目 | 無料プラン | このゲートウェイでの見込み |
|---|---|---|
| Worker のリクエスト | 10 万回 / 日（UTC 0 時にリセット） | AI 呼び出し 1 回につき 1 回程度。当面は十分 |
| CPU 時間 | **1 リクエスト 10 ms** | 中継は待ち時間が中心で、CPU はあまり使わない。App Attest の初回検証だけ重め |
| Durable Objects | SQLite 版のみ・保存容量は合計 5 GB | 対応済み。容量も十分 |
| KV の読み取り | 10 万回 / 日 | 十分 |
| **KV の書き込み** | **1,000 回 / 日** | **最初に当たるのはここ** |

**KV の書き込みが先に尽きる理由** — 購読状態のキャッシュは切れるたびに書き直し、
この確認は無料ユーザーの呼び出しでも走る。セッションの発行でも 1 人 1 日 3 回ほど書く。
キャッシュを **10 分 → 1 時間**に延ばして書き直しは 1/6 に減らしたが、
それでも 1 日に使う人が数百人規模になると当たる。
当たると購読状態のキャッシュが書けず、セッションも発行できなくなる。

| いつ | どうする |
|---|---|
| Shipaton の提出・審査の間 | 無料プランのままでよい |
| 使う人が増えてきた | **Workers Paid（月 $5）** にする。KV の書き込みは月 100 万回、CPU は 1 リクエスト 30 秒、Worker は月 1,000 万リクエストまで込み。いちばん確実 |
| 無料のまま粘りたい | 購読状態のキャッシュ（`SUBSCRIPTION_CACHE_SECONDS`）は **1 時間に延ばし済み**。さらに延ばす余地はあるが、Webhook が止まったときに解約が効くまでの時間も延びる |

CPU の 10 ms を超えると、その呼び出しはエラー（1102）になる。
ダッシュボードで CPU 時間が 10 ms に近づいていたら、有料にする合図。

Anthropic の API 利用料は Cloudflare とは別に、Anthropic のアカウントに請求される。

---

## チェックリスト

- [ ] `npx wrangler login`（ブログと同じアカウント）
- [ ] KV を作り、id を `wrangler.toml` に
- [ ] `APP_ID` を `<TeamID>.app.journalmate.JournalMate` に
- [ ] `routes` に `api.<自分のドメイン>` を追加
- [ ] 秘密: `ANTHROPIC_API_KEY` / `RC_SECRET_KEY` / `RC_WEBHOOK_SECRET` / `SESSION_SECRET`
- [ ] 秘密: `APPLE_ROOT_CA_PEM`
- [ ] 秘密: `DEVICECHECK_KEY_P8` / `DEVICECHECK_KEY_ID` / `APPLE_TEAM_ID`
- [ ] `npm test` → `npx wrangler deploy`
- [ ] `curl` で `/v1/challenge` と 401 を確認
- [ ] `BillingConfig.gateway` に URL、Xcode に App Attest
- [ ] RevenueCat の Webhook
- [ ] `ATTEST_MODE = "on"` を確認、実機で 1 回通す
- [ ] Anthropic Console で Spend limit
