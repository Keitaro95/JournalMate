#!/bin/sh
# 申請前の品質確認をまとめて回す。
#
#   sh Verification/test-all.sh                 # シミュレータ（iPhone 17）
#   sh Verification/test-all.sh device          # USB / 同じ Wi-Fi で繋いだ実機（1 台目）
#   sh Verification/test-all.sh device <UDID>   # 実機を指定
#
# 1. データ層（macOS 上で Core/ + AI/ を実行）
# 2. 中継サーバ（Gateway の vitest）
# 3. アプリのユニットテスト（JournalMateTests・端末の上で Store / 課金判定 / バックアップ往復）
# 4. アプリの UI テスト（JournalMateUITests・起動 → オンボーディング → 各タブ → Paywall → 保存）
#
# 実機では、端末の「設定 > プライバシーとセキュリティ > デベロッパモード」をオンにしておくこと。
set -e
set -o pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [ "$1" = "device" ]; then
  UDID="$2"
  if [ -z "$UDID" ]; then
    UDID=$(xcrun xctrace list devices 2>/dev/null \
      | sed -n '/== Devices ==/,/== Devices Offline ==/p' \
      | grep -v -e '==' -e 'Mac' | grep -oE '\(([0-9A-Fa-f-]{20,})\)$' | tr -d '()' | head -1)
  fi
  if [ -z "$UDID" ]; then
    echo "実機が見つかりません。ケーブルで繋ぎ、「このコンピュータを信頼」してください。" >&2
    exit 1
  fi
  DESTINATION="platform=iOS,id=$UDID"
else
  DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
fi

RESULTS="Verification/results"
mkdir -p "$RESULTS"
STAMP=$(date +%Y%m%d-%H%M%S)

echo "== 1/4 データ層"
sh Verification/run.sh | tail -1

echo "== 2/4 中継サーバ"
(cd Gateway && npm test --silent 2>&1 | grep -E "Tests|failed" )

echo "== 3/4 + 4/4 アプリ（${DESTINATION}）"
xcodebuild test \
  -project JournalMate.xcodeproj \
  -scheme "JournalMate Tests" \
  -destination "$DESTINATION" \
  -allowProvisioningUpdates \
  -resultBundlePath "$RESULTS/$STAMP.xcresult" \
  2>&1 | grep -E "error:|✘|Test Case .*(passed|failed)|✔ Test run|TEST (SUCCEEDED|FAILED)|Executed .* tests"

echo "結果: $RESULTS/$STAMP.xcresult（Xcode で開くと画面ごとの記録が見られる）"
