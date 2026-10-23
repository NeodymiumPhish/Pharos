#!/bin/bash
# Standalone test runner for NavigatorPaneState: what the Database Navigator's
# pane shows while there is no tree (no connection, a read running, a read
# that failed).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t navigator-pane-state-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Core/NavigatorPaneState.swift \
  PharosTests/NavigatorPaneStateTests.swift \
  PharosTests/main.swift
"$BIN"
