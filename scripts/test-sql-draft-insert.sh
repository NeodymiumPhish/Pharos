#!/bin/bash
# Standalone test runner for SQLTextView.insertDraft — the edit that puts a
# model draft in the editor. Real AppKit, headless; no window is shown.
# Settings.swift comes along because ExportFormat and CsvDialect moved there
# — `AppSettings.dataExport` names them, and a type AppSettings names must
# compile with Settings.swift alone. ChartPalette is what Settings.swift
# itself needs.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/sql-draft-insert-tests \
  Pharos/Editor/SQLTextView.swift \
  Pharos/Editor/VariableCompletion.swift \
  Pharos/Core/VariableSubstitutor.swift \
  Pharos/Core/VariableValuePreview.swift \
  Pharos/Models/QueryVariable.swift \
  Pharos/Editor/SQLCompletionProvider.swift \
  Pharos/Editor/SQLStatementScope.swift \
  Pharos/Editor/CompletionResolver.swift \
  Pharos/Editor/SQLSegmentParser.swift \
  Pharos/Editor/CompletionTriggerPolicy.swift \
  Pharos/Editor/KeywordCasing.swift \
  Pharos/Editor/SQLSyntaxHighlighter.swift \
  Pharos/Editor/SQLListFormatter.swift \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Editor/FoldState.swift \
  Pharos/Editor/FoldingLayoutManager.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Models/Schema.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  PharosTests/SQLDraftInsertTests.swift \
  PharosTests/main.swift
/tmp/sql-draft-insert-tests
