#!/bin/bash
# Standalone test runner for ResultTabRowCell — no Xcode project involvement.
# The cell lives outside ResultTabsPanelVC precisely so it can be compiled here
# without the PharosCore FFI bridge.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/result-tab-row-cell-tests \
  Pharos/Views/ResultTabRowCell.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/HistoryRowText.swift \
  PharosTests/ResultTabRowCellTests.swift \
  PharosTests/main.swift
/tmp/result-tab-row-cell-tests
