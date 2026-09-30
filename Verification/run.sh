#!/bin/sh
# データ層（Core + AI）を Xcode なしで検証する。
# UI は iOS 専用だが、この層は macOS SDK だけでビルドして実際に動かせる。
#
#   sh Verification/run.sh
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
xcrun swiftc -swift-version 6 -target arm64-apple-macosx14.0 -parse-as-library \
  JournalMate/Core/*.swift JournalMate/AI/*.swift Verification/DataLayerChecks.swift \
  -o "$OUT/checks"
"$OUT/checks"
