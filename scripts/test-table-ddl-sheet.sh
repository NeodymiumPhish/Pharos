#!/bin/bash
# Standalone test runner for the clone section of TableDDLSheet. Uses real
# AppKit through a headless NSWindow, like scripts/test-tag-manager-sheet.sh.
#
# Schema.swift is here because the clone callback carries `CloneRowScope`,
# which lives beside `CloneTableOptions`; Settings.swift and ChartPalette.swift
# come with it, as they do in the other nine harnesses that compile it.
# FoldState/FoldingLayoutManager come because the DDL text view is built on the
# disclosing layout manager, and the authored-label sanitiser (with Toast and
# SanitiseNotice behind it) because the clone NAME field is sanitised as it is
# typed.
#
# The binary goes in a fresh mktemp dir, NOT a fixed /tmp name: the older
# scripts share those, so two concurrent sweeps clobber each other.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=$(mktemp -d)/table-ddl-sheet-tests
swiftc -o "$BIN" \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Core/CountedNounText.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/SanitiseNotice.swift \
  Pharos/Editor/FoldState.swift \
  Pharos/Editor/FoldingLayoutManager.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Models/Schema.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/TableDDL.swift \
  Pharos/Views/NSTextField+AuthoredLabel.swift \
  Pharos/Views/Toast.swift \
  Pharos/Sheets/TableDDLSheet.swift \
  PharosTests/TableDDLSheetTests.swift \
  PharosTests/main.swift
"$BIN"
