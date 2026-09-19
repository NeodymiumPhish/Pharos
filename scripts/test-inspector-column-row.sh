#!/bin/bash
# Standalone test runner for the Inspector's Columns-section row. Real AppKit,
# headless: layout and the pasteboard need no window.
#
# InspectorViewController itself is excluded — it pulls in the PharosCore FFI
# bridge, which cannot link in a plain swiftc binary; the row lives in its own
# file for exactly that reason.
#
# The binary name is unique to this suite: every test-*.sh writes a fixed path,
# and two suites sharing one would clobber each other when run concurrently.
# Settings.swift comes along because ExportFormat and CsvDialect moved there
# — `AppSettings.dataExport` names them, and a type AppSettings names must
# compile with Settings.swift alone. ChartPalette is what Settings.swift
# itself needs.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/inspector-column-row-tests \
  Pharos/Views/InspectorColumnRowView.swift \
  Pharos/Models/Schema.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Utilities/SqlIdentifierQuoting.swift \
  Pharos/Core/DisplayEscape.swift \
  PharosTests/InspectorColumnRowTests.swift \
  PharosTests/main.swift
/tmp/inspector-column-row-tests
