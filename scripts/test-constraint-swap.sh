#!/bin/bash
# Standalone test runner for NSLayoutConstraint.swap and the views that use
# it — real AppKit in a never-shown window, no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-constraint-swap-tests \
  "Pharos/Utilities/NSLayoutConstraint+Swap.swift" \
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
  Pharos/Settings/Furniture/SettingsRow.swift \
  Pharos/Settings/Furniture/SettingsMetrics.swift \
  PharosTests/ConstraintSwapTests.swift \
  PharosTests/main.swift
/tmp/pharos-constraint-swap-tests
