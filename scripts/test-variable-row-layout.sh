#!/bin/bash
# Standalone test runner for VariableValueTextView / VariableRowView — no
# Xcode project involvement. Unlike the other scripts/test-*.sh runners, this
# one exercises real AppKit: Auto Layout, hit-testing and resolved colours,
# via a headless (never-shown) NSWindow.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
swiftc -o /tmp/variable-row-layout-tests \
  Pharos/ViewControllers/QueryVariables/VariableRowView.swift \
  Pharos/ViewControllers/QueryVariables/VariableListView.swift \
  Pharos/ViewControllers/QueryVariables/VariableValueTextView.swift \
  Pharos/Core/VariableSubstitutor.swift \
  Pharos/Core/VariableValuePreview.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Editor/FoldState.swift \
  Pharos/Editor/FoldingLayoutManager.swift \
  Pharos/Models/QueryVariable.swift \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  PharosTests/VariableRowLayoutTests.swift \
  "$TMPMAIN"
/tmp/variable-row-layout-tests
