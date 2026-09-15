#!/bin/bash
# Standalone test runner for the results area's pending-edits bar. Uses real
# AppKit through a headless NSWindow, like scripts/test-import-data-sheet.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pending-edits-bar-tests \
  Pharos/Core/CountedNounText.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Views/PendingEditsBar.swift \
  PharosTests/PendingEditsBarTests.swift \
  PharosTests/main.swift
/tmp/pending-edits-bar-tests
