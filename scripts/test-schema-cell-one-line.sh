#!/bin/bash
# Standalone test runner for the schema browser's one-line row cell — real
# AppKit Auto Layout, headless (the cell is laid out by hand at each of the
# source list's row heights; no window is needed for a layout measurement).
#
# SchemaBrowserVC itself is excluded: it pulls in the PharosCore FFI bridge,
# which cannot link in a plain swiftc binary. Only the cell and the node it
# renders are compiled.
#
# The binary name is unique to this suite: every test-*.sh writes a fixed path,
# and two suites sharing one would clobber each other when run concurrently.
# Settings.swift comes along because ExportFormat and CsvDialect moved there
# — `AppSettings.dataExport` names them, and a type AppSettings names must
# compile with Settings.swift alone. ChartPalette is what Settings.swift
# itself needs.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/schema-cell-one-line-tests \
  Pharos/Views/SchemaTreeCellView.swift \
  Pharos/Models/SchemaTreeNode.swift \
  Pharos/Models/Schema.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Models/PartitionDisplay.swift \
  Pharos/Models/ColumnTypeIcon.swift \
  Pharos/Core/DisplayEscape.swift \
  PharosTests/SchemaCellOneLineTests.swift \
  PharosTests/main.swift
/tmp/schema-cell-one-line-tests
