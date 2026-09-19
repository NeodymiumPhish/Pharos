#!/bin/bash
# Standalone test runner for what a Results History row says, and above all for
# what a FAILED row says out loud: the warning glyph is invisible to a screen
# reader, so the spoken label has to name the failure in words.
# Pure Foundation, no AppKit, no FFI.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=$(mktemp -d)/history-row-text-tests
swiftc -o "$BIN" \
  Pharos/Models/QueryHistoryStatus.swift \
  Pharos/Core/HistoryRowText.swift \
  PharosTests/HistoryRowTextTests.swift \
  PharosTests/main.swift
"$BIN"
