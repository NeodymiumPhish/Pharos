#!/bin/bash
# Standalone test runner for the Variable Manager's content: VariableManagerVC
# in the manager shell (sidebar rows, the settle/prune/collision rules, the
# toolbar, Delete and Duplicate, the store-republish rule) and
# VariableConnectionsView (global or linked) in the form's Connections box.
# Real AppKit in a window ordered in offscreen.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/variable-manager-tests \
  Pharos/ViewControllers/QueryVariables/VariableManagerVC.swift \
  Pharos/ViewControllers/QueryVariables/VariableConnectionsView.swift \
  Pharos/ViewControllers/QueryVariables/VariableDetailVC.swift \
  Pharos/ViewControllers/QueryVariables/VariableValueEditors.swift \
  Pharos/ViewControllers/QueryVariables/VariableValueTextView.swift \
  Pharos/Windows/Manager/*.swift \
  Pharos/Settings/Furniture/SettingsSymbolBadge.swift \
  Pharos/Settings/Furniture/SettingsMetrics.swift \
  Pharos/Settings/Furniture/SettingsGroupBox.swift \
  Pharos/Settings/Furniture/SettingsRow.swift \
  Pharos/Settings/Furniture/SettingsSectionHeader.swift \
  Pharos/Settings/Furniture/SettingsControlFactory.swift \
  Pharos/Settings/Furniture/SettingsFormDocumentView.swift \
  Pharos/Settings/Furniture/SettingsFooterButtonRow.swift \
  "Pharos/Utilities/NSLayoutConstraint+Swap.swift" \
  Pharos/Views/ConnectionMenuArt.swift \
  Pharos/Views/TabConnectionDot.swift \
  Pharos/Views/EmptyStateView.swift \
  Pharos/Core/TimeZoneChoices.swift \
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
