#!/bin/bash
# Standalone test runner for the Variable Manager's content: VariableManagerVC
# (list | detail, the panel's settle/prune/collision rules) and
# VariableConnectionsView (global or linked). Headless AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/variable-manager-tests \
  Pharos/ViewControllers/QueryVariables/VariableManagerVC.swift \
  Pharos/ViewControllers/QueryVariables/VariableConnectionsView.swift \
  Pharos/ViewControllers/QueryVariables/VariableListView.swift \
  Pharos/ViewControllers/QueryVariables/VariableRowView.swift \
  Pharos/ViewControllers/QueryVariables/VariableDetailVC.swift \
  Pharos/ViewControllers/QueryVariables/VariableValueTextView.swift \
  "Pharos/Utilities/NSLayoutConstraint+Swap.swift" \
  Pharos/Views/ConnectionMenuArt.swift \
  Pharos/Views/TabConnectionDot.swift \
  Pharos/Views/EmptyStateView.swift \
  Pharos/Core/VariableSubstitutor.swift \
  Pharos/Core/VariableValueRules.swift \
  Pharos/Core/VariableValuePreview.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Editor/FoldState.swift \
  Pharos/Editor/FoldingLayoutManager.swift \
  Pharos/Core/PulseClock.swift \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Editor/SQLSegmentParser.swift \
  Pharos/Editor/SQLFoldingParser.swift \
  Pharos/Editor/LineNumberGutter.swift \
  Pharos/Views/MarkerShape.swift \
  Pharos/Core/AccessibilityDisplay.swift \
  Pharos/Core/CountedNounText.swift \
  Pharos/Models/QueryVariable.swift \
  Pharos/Models/Connection.swift \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Views/NSTextField+AuthoredLabel.swift \
  Pharos/Core/SanitiseNotice.swift \
  Pharos/Views/Toast.swift \
  PharosTests/VariableManagerTests.swift \
  PharosTests/main.swift
/tmp/variable-manager-tests
