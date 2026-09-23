#!/bin/bash
# Standalone test runner for the SQL editor's completion behaviour — the `{{`
# variable list, the dot rule and the `complete:` action — typed into a real
# SQLTextView + SQLCompletionProvider. No Xcode project involvement.
#
# The binary name is unique to this suite: every test-*.sh writes a fixed path,
# and two suites sharing one would clobber each other when run concurrently.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-editor-completion-tests \
  Pharos/Editor/SQLCompletionProvider.swift \
  Pharos/Editor/SQLTextView.swift \
  Pharos/Editor/VariableCompletion.swift \
  Pharos/Core/VariableSubstitutor.swift \
  Pharos/Models/QueryVariable.swift \
  Pharos/Editor/SQLSyntaxHighlighter.swift \
  Pharos/Editor/SQLListFormatter.swift \
  Pharos/Editor/CompletionTriggerPolicy.swift \
  Pharos/Editor/KeywordCasing.swift \
  Pharos/Editor/SQLThemeCatalog.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Editor/FoldState.swift \
  Pharos/Editor/FoldingLayoutManager.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Models/Schema.swift \
  PharosTests/EditorCompletionTests.swift \
  PharosTests/main.swift
/tmp/pharos-editor-completion-tests
