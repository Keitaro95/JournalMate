撮影 → Clef 判定 → アバター表示 → 編集の最小構成を、Worker と SwiftUI のコードで書きます。まず Clef の応答形式を確認します。

その流れで動く最小構成を、Worker 2ファイルと SwiftUI 6ファイルで書きました。Worker は型チェックを通していますが、Swift 側はこの環境にコンパイラがなく未ビルドです。Xcode で一度ビルドして確認してください。Clef の実呼び出しも未実行です。

流れとファイルの対応
段階	ファイル	やっていること
撮影	CameraPicker.swift	インカメラで1枚撮る（シミュレータでは写真ライブラリに切り替え）
送信	ClefClient.swift	長辺 1024px の JPEG に縮め、data URL で Worker に POST
判定	index.ts	31問を1リクエストで Clef に送り、結果を整えて返す
変換	AvatarConfig.swift	返ってきた JSON を31項目の設定に詰める
表示	AvatarView.swift	設定からパーツを奥から順に重ねて描く（Web 版の CSS に当たる部分）
編集	AvatarEditorView.swift	カテゴリのタブと選択肢チップで設定を書き換える
全体	AvatarMakerApp.swift	上記をつなぐ画面、設定の保存、画像の共有

Worker がアプリに返す JSON はこの形です。

json
{ "answers": { "faceShape": { "value": "round", "confidence": 0.48 },
               "smiling":   { "value": "no",    "confidence": 0.99 } },
  "ms": 1215 }

編集画面では、確率が 60% 未満の項目に「要確認」バッジが付きます。「AIの結果に戻す」で判定直後の状態に戻せます。

動かす手順
worker フォルダで npx wrangler deploy を実行し、表示された URL を控えます。
Xcode で iOS 17 以降の SwiftUI アプリを新規作成し、Swift 6ファイルを追加します（自動生成された App と ContentView は削除）。
ClefClient.swift の endpoint を手順1の URL に書き換えます。
Info.plist に NSCameraUsageDescription（カメラの使用理由）を追加します。
実機でビルドします。
知っておくべき点
質問文は私が書いたものです: 元のデモの31項目はスクリーンショットから再現しましたが、選択肢と英語の質問文は推測です。判定がずれる項目は index.ts の文言を調整してください。
選択肢の id は両側で一致が必要です: Worker の質問 id・選択肢 id と Swift の enum は、現状は全31項目で一致を確認済みです。項目を増やすときは両方を直してください。
Worker は既定で誰でも呼べます: wrangler secret put APP_TOKEN を設定すると、ヘッダーの合言葉が必須になります。ただしアプリに埋め込む値なので、本格的に公開するならレート制限も必要です。
絵は素朴です: パーツは円や曲線で描いた簡易なもので、見た目の作り込みは AvatarView.swift の各関数を差し替えていく形になります。