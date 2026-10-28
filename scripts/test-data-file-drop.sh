#!/bin/bash
# D1: a data file dropped on a card editor, through a stand-in NSDraggingInfo.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t data-file-drop-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Editor/SQLTextView.swift \
  Pharos/Core/DataFiles.swift \
  Pharos/Editor/VariableCompletion.swift \
  Pharos/Core/VariableSubstitutor.swift \
  Pharos/Core/VariableValueRules.swift \
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
  PharosTests/DataFileDropTests.swift \
  PharosTests/main.swift
"$BIN"
