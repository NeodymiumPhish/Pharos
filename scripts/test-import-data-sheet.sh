#!/bin/bash
# Standalone test runner for ImportDataSheet. Uses real AppKit through a
# headless NSWindow, like scripts/test-export-data-sheet.sh.
# Settings.swift carries ExportFormat, CsvDialect and the two Export & Import
# settings structs, and ChartPalette is what Settings.swift itself needs.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/import-data-sheet-tests \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Models/Schema.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  Pharos/Sheets/ImportDataSheet.swift \
  PharosTests/ImportDataSheetTests.swift \
  PharosTests/main.swift
/tmp/import-data-sheet-tests
