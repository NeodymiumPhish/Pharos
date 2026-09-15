#!/bin/bash
# Standalone test runner for ConnectionColor — the connection colour label's
# fixed palette and the values the menus and the editor band draw from it.
# No Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t connection-color-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Models/Connection.swift \
  PharosTests/ConnectionColorTests.swift \
  PharosTests/main.swift
"$BIN"
