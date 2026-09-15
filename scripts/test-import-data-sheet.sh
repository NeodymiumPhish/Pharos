#!/bin/bash
# Standalone test runner for ImportDataSheet. Uses real AppKit through a
# headless NSWindow, like scripts/test-export-data-sheet.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/import-data-sheet-tests \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  Pharos/Sheets/ImportDataSheet.swift \
  PharosTests/ImportDataSheetTests.swift \
  PharosTests/main.swift
/tmp/import-data-sheet-tests
