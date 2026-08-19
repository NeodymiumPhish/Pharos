#!/bin/bash
# Standalone test runner for VariableDetailVC — no Xcode project involvement.
# Separate binary from test-variable-row-layout.sh because only one runTests()
# can exist per compiled binary; this one exercises real AppKit (Auto Layout,
# hit-testing, resolved colours, text-view round-tripping) via a headless
# (never-shown) NSWindow, same technique as the row/list harness.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
swiftc -o /tmp/variable-detail-vc-tests \
  Pharos/ViewControllers/QueryVariables/VariableDetailVC.swift \
  Pharos/ViewControllers/QueryVariables/VariableValueTextView.swift \
  Pharos/Core/VariableSubstitutor.swift \
  Pharos/Core/VariableValuePreview.swift \
  Pharos/Core/PulseClock.swift \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLSegmentParser.swift \
  Pharos/Editor/SQLFoldingParser.swift \
  Pharos/Editor/LineNumberGutter.swift \
  Pharos/Models/QueryVariable.swift \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  PharosTests/VariableDetailVCTests.swift \
  "$TMPMAIN"
/tmp/variable-detail-vc-tests
