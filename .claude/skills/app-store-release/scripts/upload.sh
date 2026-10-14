#!/bin/sh
# Release で Archive して、App Store Connect へアップロードする。
#
#   sh .claude/skills/app-store-release/scripts/upload.sh
#
# バージョンとビルド番号は project.pbxproj の値をそのまま使う（先に上げてコミットしておく）。
set -e
cd "$(dirname "$0")/../../../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

HERE=".claude/skills/app-store-release"
ARCHIVE="build/JournalMate.xcarchive"
rm -rf "$ARCHIVE" build/export

xcodebuild archive \
  -project JournalMate.xcodeproj \
  -scheme JournalMate \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  2>&1 | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

echo "Archive の中身:"
/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleShortVersionString" -c "Print :ApplicationProperties:CFBundleVersion" "$ARCHIVE/Info.plist"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$HERE/ExportOptions.plist" \
  -exportPath build/export \
  -allowProvisioningUpdates \
  2>&1 | grep -E "error:|Upload succeeded|EXPORT (SUCCEEDED|FAILED)"
