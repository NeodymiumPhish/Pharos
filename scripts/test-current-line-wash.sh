#!/bin/bash
# Standalone test runner for the caret-line wash — what it PAINTS, and what it
# leaves of the syntax colors drawn on top of it. Renders the real SQLTextView
# offscreen into an NSBitmapImageRep: no window is shown, no screen capture, no
# Screen Recording or Accessibility permission.
#
# The file list mirrors scripts/test-sql-draft-insert.sh, which is the other
# harness that compiles SQLTextView: Settings.swift comes along because
# AppSettings names ExportFormat and CsvDialect, and ChartPalette is what
# Settings.swift itself needs.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t current-line-wash-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Editor/SQLTextView.swift \
  Pharos/Editor/VariableCompletion.swift \
  Pharos/Core/VariableSubstitutor.swift \
  Pharos/Models/QueryVariable.swift \
  Pharos/Editor/SQLCompletionProvider.swift \
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
  PharosTests/CurrentLineWashTests.swift \
  PharosTests/main.swift
"$BIN"
