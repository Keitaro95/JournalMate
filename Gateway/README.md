# JournalMate Gateway

契約者の AI 呼び出しを中継する Cloudflare Worker。
**Anthropic の API キーをアプリに埋め込まないために存在する**（埋めればバイナリから抜かれ、
請求はこちらに来る）。アプリ側の設計は [../development.md §5](../development.md#5-課金) に。

やることは 4 つだけ。

```
アプリ ──POST /v1/messages──▶ ここ ──▶ api.anthropic.com
                               │ ① 本物のアプリか        App Attest → JWT     … 401
                               │ ② 契約中か／無料枠内か  RevenueCat・端末     … 402
                               │ ③ 今日の上限内か        Durable Object       … 429
                               │ ④ 渡してよい body か    モデル・max_tokens   … 400
                               ▼
                        SSE は素通しで返す（バッファしない）
```

未契約者も、**無料枠のある機能だけ**は通す（いまは `journal_extract` の月 20 回）。
その呼び出しはモデルを Haiku に固定し、出力も絞る。
**入れ直しで枠を戻させないために DeviceCheck を使う** — 端末ごとの 2 ビットは
アプリを削除しても Apple 側に残るので、「この端末は今月の無料枠を開始した」を覚えられる。

## エンドポイント

| | 用途 | 認証 |
|---|---|---|
| `POST /v1/challenge` | 使い捨てのチャレンジ（5 分） | なし |
| `POST /v1/session` | attestation / assertion → セッション JWT（24 時間） | App Attest |
| `POST /v1/messages` | Anthropic への中継（契約 → トライアル → 無料枠の順に判定） | `Authorization: Bearer <JWT>` |
| `POST /v1/trial/start` | 7 日間の無料トライアルを始める（1 端末 1 回。使用済みは 409） | `Authorization: Bearer <JWT>` ＋ `x-device-token` |
| `POST /webhooks/revenuecat` | 購読状態の押し込み | 共有シークレット |

応答には残量が載る。**アプリ側で日付を計算させない**（端末の時計に依らせない）。

```
x-budget-limit: 400000
x-budget-used:  32100
x-budget-reset: 1758672000   ← UTC 翌 0 時（epoch 秒）
```

## セットアップ

Cloudflare の画面とコマンドでやることは、説明付きで [../cloudflare.md](../cloudflare.md) にまとめてある。

```sh
npm install
npx wrangler login
```

1. **KV を作る** — `npx wrangler kv namespace create CACHE` で出た id を
   `wrangler.toml` の `REPLACE_WITH_KV_ID` に入れる
2. **`APP_ID` を入れる** — `<TeamID>.<BundleID>`（例 `ABCDE12345.app.journalmate`）
3. **Apple のルート CA を入れる** — [Apple の配布ページ](https://www.apple.com/certificateauthority/)
   から `Apple App Attestation Root CA` の PEM を落として:
   ```sh
   npx wrangler secret put APPLE_ROOT_CA_PEM < Apple_App_Attestation_Root_CA.pem
   ```
4. **残りの秘密を入れる**
   ```sh
   npx wrangler secret put ANTHROPIC_API_KEY    # sk-ant-...
   npx wrangler secret put RC_SECRET_KEY        # RevenueCat の secret キー（公開キーとは別物）
   npx wrangler secret put RC_WEBHOOK_SECRET    # 任意の文字列。RevenueCat 側にも同じものを設定
   npx wrangler secret put SESSION_SECRET       # openssl rand -base64 48
   ```
5. **DeviceCheck の鍵を入れる**（無料枠を端末に縛るため。入れないと入れ直しで枠が戻る）
   App Store Connect > Integrations > Keys で DeviceCheck 用の鍵を作り、.p8 を落として:
   ```sh
   npx wrangler secret put DEVICECHECK_KEY_P8 < AuthKey_XXXXXXXXXX.p8
   npx wrangler secret put DEVICECHECK_KEY_ID   # 鍵の Key ID
   npx wrangler secret put APPLE_TEAM_ID        # Team ID
   # 開発端末のトークンで試すときは wrangler.toml に DEVICECHECK_ENV = "development"
   ```
6. **デプロイ** — `npx wrangler deploy`
7. **アプリに URL を入れる** — `JournalMate/AI/BillingConfig.swift` の `gateway` に
   デプロイ先（`https://journalmate-gateway.<account>.workers.dev`）を入れる
8. **RevenueCat の Webhook** を `https://<デプロイ先>/webhooks/revenuecat` に向け、
   Authorization ヘッダに `RC_WEBHOOK_SECRET` と同じ値を設定する

### シミュレータで動かすとき

App Attest はシミュレータでは動かない（`DCAppAttestService.isSupported` が false）。
開発中だけ合言葉で通す:

```sh
npx wrangler secret put DEV_BYPASS_TOKEN
# wrangler.toml の ATTEST_MODE を "off" にする
```

アプリ側は、Xcode の Scheme の環境変数 `GATEWAY_DEV_BYPASS` に同じ値を入れる
（DEBUG のシミュレータ実行でだけ読む。手順は [../cloudflare.md §7](../cloudflare.md)）。

`ATTEST_MODE = "off"` は**開発専用**。この状態では誰でもセッションを取れる。

## 確認

```sh
npm test        # 70 項目（body の検査・計量・台帳・JWT・CBOR・署名の取り回し）
npm run typecheck
npx wrangler dev
```

## 設計上の決め

| 論点 | 決め | なぜ |
|---|---|---|
| 台帳の置き場所 | **Durable Object**（1 ユーザー 1 個） | KV は結果整合。同時リクエストが同じ残量を読んで両方通り、上限を越える |
| 日の境界 | **UTC 固定** | 端末のタイムゾーンで数えると、設定を変えるだけで枠が戻る |
| 上限の数え方 | 仮押さえ → 実測で精算 | ストリームは走り出すと止まらない。`max_tokens` ぶんを先に押さえないと 1 回で飛び越える |
| 落ちた接続 | 仮押さえは 5 分で失効 | 精算されない押さえが永久に居座るのを防ぐ |
| 失敗した呼び出し | 生成されたぶんは積む | 途中まで出ていれば実際に課金されている |
| body | **許可したキーだけ通す** | 素通しにすると、URL を知った人の無料 Claude プロキシになる |
| RevenueCat 障害時 | 直前のキャッシュを使う | 向こうが落ちたときに全員を締め出さない |
| 購読状態のキャッシュ | **1 時間**。アプリの申告（`X-Plan`）と食い違えば聞き直す（1 分に 1 回まで） | 無料プランの KV は書き込みが 1 日 1,000 回。変化は Webhook で届く。購入直後だけは申告で即時に直す |
| 主キー | **端末 ID**（アプリが Keychain の「この端末限定」に置く UUID。JWT の `sub`、RevenueCat の appUserID も同じ） | 契約・使用量・無料枠・トライアルを 1 つの ID で数える。入れ直しても変わらないので、使用量が白紙に戻らない |
| keyId と端末 ID | 初回で結びつけ、以後は変えさせない。keyId は本物のアプリかの確認にだけ使う | App Attest が言えるのは「本物のアプリ」までで「どの端末か」ではない。1 つの鍵で複数の端末 ID を名乗って枠を食うのを止める |
| 無料枠・トライアルの縛り | 端末 ID ＋ **DeviceCheck の 2 ビット** | 入れ直しは端末 ID で塞げるが、端末の初期化で端末 ID も消える。Apple 側に残るビットだけが初期化まで見抜ける |
| 無料枠の月次リセット | ビットの `last_update_time` を見る | cron も alarm も要らない。先月のビットは自動的に無効 |
| DeviceCheck が落ちたとき | 通す | 無料ユーザーを締め出さない。総額は共有プールの天井で守る |
| 無料の呼び出しのモデル | サーバが Haiku に固定 | 1 回あたりを安くしておくことが、無料枠を開けられる条件 |

## 残っている確認

`src/attest.ts` の Apple 証明書まわりだけは、**実機の attestation を通していない**。
オフラインのテストで確かめているのは部品（CBOR・authData・DER 署名・nonce の取り出し）まで。
最初に実機で 1 回通し、`console.warn("attest failed")` が出ないことを見ること。
