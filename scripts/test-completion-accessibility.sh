#!/bin/bash
# Standalone test runner for SQL autocomplete accessibility — no Xcode project
# involvement. SQLCompletionProvider holds a weak SQLTextView, so the text view
# and its editor dependencies come along to typecheck.
#
# The binary name is unique to this suite: every test-*.sh writes a fixed path,
# and two suites sharing one would clobber each other when run concurrently.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/completion-accessibility-tests \
  Pharos/Editor/SQLCompletionProvider.swift \
  Pharos/Editor/SQLTextView.swift \
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
  PharosTests/CompletionAccessibilityTests.swift \
  PharosTests/main.swift
/tmp/completion-accessibility-tests
