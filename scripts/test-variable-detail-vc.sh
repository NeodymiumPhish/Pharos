#!/bin/bash
# Standalone test runner for VariableDetailVC, the Variable Manager's form —
# no Xcode project involvement. Real AppKit (Auto Layout, field editors,
# popovers, resolved colours, offscreen renders) in a titled window ordered in
# offscreen. See PharosTests/VariableDetailVCTests.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
swiftc -o /tmp/variable-detail-vc-tests \
  Pharos/ViewControllers/QueryVariables/VariableDetailVC.swift \
  Pharos/ViewControllers/QueryVariables/VariableValueEditors.swift \
  Pharos/ViewControllers/QueryVariables/VariableValueTextView.swift \
  Pharos/ViewControllers/QueryVariables/VariableConnectionsView.swift \
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
  Pharos/Models/Connection.swift \
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
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Views/NSTextField+AuthoredLabel.swift \
  Pharos/Core/SanitiseNotice.swift \
  Pharos/Views/Toast.swift \
  PharosTests/VariableDetailVCTests.swift \
  "$TMPMAIN"
/tmp/variable-detail-vc-tests
