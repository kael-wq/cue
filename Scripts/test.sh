#!/bin/bash
# 无 Xcode / XCTest 环境下的轻量自测
# 用法: ./Scripts/test.sh   （或 sh Scripts/test.sh）
set -e
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp Scripts/selftest.swift "$TMP/main.swift"
swiftc Sources/Cue/HistoryStore.swift \
       Sources/Cue/CLI.swift \
       Sources/Cue/ClipDaemon.swift \
       Sources/Cue/ClipRules.swift \
       "$TMP/main.swift" \
       -o "$TMP/selftest"
"$TMP/selftest"
