#!/bin/bash
# Standalone test runner for ExportDataSheet. Uses real AppKit through a
# headless NSWindow, like scripts/test-query-error-sheet.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/export-data-sheet-tests \
  Pharos/Models/Schema.swift \
  Pharos/Views/NSTextField+FormLabel.swift \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  Pharos/Sheets/ExportDataSheet.swift \
  PharosTests/ExportDataSheetTests.swift \
  PharosTests/main.swift
/tmp/export-data-sheet-tests
