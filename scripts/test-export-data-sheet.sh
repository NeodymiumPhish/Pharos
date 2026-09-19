#!/bin/bash
# Standalone test runner for ExportDataSheet. Uses real AppKit through a
# headless NSWindow, like scripts/test-query-error-sheet.sh.
# Settings.swift carries ExportFormat, CsvDialect and the two Export & Import
# settings structs, and ChartPalette is what Settings.swift itself needs.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/export-data-sheet-tests \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Files/SavedQueryFilename.swift \
  Pharos/Models/Schema.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Core/ExportImportOutcomeText.swift \
  Pharos/Views/NSTextField+FormLabel.swift \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  Pharos/Sheets/ExportDataSheet.swift \
  PharosTests/ExportDataSheetTests.swift \
  PharosTests/main.swift
/tmp/export-data-sheet-tests
