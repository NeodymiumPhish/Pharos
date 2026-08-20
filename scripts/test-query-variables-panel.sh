#!/bin/bash
# Standalone test runner for QueryVariablesPanelVC — no Xcode project
# involvement. Separate binary from the other two variables-panel harnesses
# (test-variable-detail-vc.sh, test-variable-row-layout.sh) because only one
# runTests() can exist per compiled binary; this one exercises the two-level
# list/detail container itself — the level swap, row-identity preservation,
# and the abandoned-`+` prune — via a headless (never-shown) NSWindow, same
# technique as the other two.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
swiftc -o /tmp/query-variables-panel-tests \
  Pharos/ViewControllers/QueryVariables/QueryVariablesPanelVC.swift \
  Pharos/ViewControllers/QueryVariables/VariableListView.swift \
  Pharos/ViewControllers/QueryVariables/VariableRowView.swift \
  Pharos/ViewControllers/QueryVariables/VariableDetailVC.swift \
  Pharos/ViewControllers/QueryVariables/VariableValueTextView.swift \
  Pharos/Core/VariableSubstitutor.swift \
  Pharos/Core/VariableValuePreview.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Editor/FoldState.swift \
  Pharos/Editor/FoldingLayoutManager.swift \
  Pharos/Core/PulseClock.swift \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLSegmentParser.swift \
  Pharos/Editor/SQLFoldingParser.swift \
  Pharos/Editor/LineNumberGutter.swift \
  Pharos/Models/QueryVariable.swift \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  PharosTests/QueryVariablesPanelTests.swift \
  "$TMPMAIN"
/tmp/query-variables-panel-tests
