#!/bin/bash
# Standalone test runner for TagManagerHostVC: the Tag Manager window's content on
# the shared manager shell — sidebar rows and the unsaved dot, selection driving
# the detail, + / New Tag, Delete key and context menu, Save and Revert, the
# discard question, the colour swatches (click, key, VoiceOver), Light/Dark
# renders with the swatch ring measured, and no constraint conflicts.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-manager-window-tests \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/Log.swift \
  Pharos/Core/PopupValueMenu.swift \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Core/RuleKey.swift \
  Pharos/Core/SanitiseNotice.swift \
  Pharos/Core/TagConditionEditor.swift \
  Pharos/Core/TagConditionKind.swift \
  Pharos/Core/TagCapture.swift \
  Pharos/Core/CountedNounText.swift \
  Pharos/Core/TagDraft.swift \
  Pharos/Core/TagFamilyLabel.swift \
  Pharos/Core/TagGlob.swift \
  Pharos/Core/TagCommitWriting.swift \
  Pharos/Core/TagManagerCommitting.swift \
  Pharos/Core/TagManagerModel.swift \
  Pharos/Core/TagPalette.swift \
  Pharos/Core/TagPredicate.swift \
  Pharos/Core/TagRuleMatcher.swift \
  Pharos/Utilities/SQLTypeName.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Tag.swift \
  Pharos/Views/HostileTextBadge.swift \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  Pharos/Views/NSTextField+AuthoredLabel.swift \
  Pharos/Views/TagCaptureListView.swift \
  Pharos/Views/TagConditionRowView.swift \
  Pharos/Views/TagRuleGridView.swift \
  Pharos/Views/Toast.swift \
  Pharos/Sheets/TagManagerSheet.swift \
  Pharos/Sheets/TagDetailVC.swift \
  Pharos/Views/TagColorSwatchPicker.swift \
  Pharos/Views/EmptyStateView.swift \
  Pharos/Settings/SettingsDetailVC.swift \
  Pharos/Settings/Furniture/SettingsMetrics.swift \
  Pharos/Settings/Furniture/SettingsFormDocumentView.swift \
  Pharos/Settings/Furniture/SettingsGroupBox.swift \
  Pharos/Settings/Furniture/SettingsRow.swift \
  Pharos/Settings/Furniture/SettingsSectionHeader.swift \
  Pharos/Settings/Furniture/SettingsFooterButtonRow.swift \
  Pharos/Utilities/NSLayoutConstraint+Swap.swift \
  Pharos/Core/TagSampleTest.swift \
  Pharos/Sheets/TagAddValuesSheet.swift \
  Pharos/Core/TagValueImport.swift \
  Pharos/Sheets/TagManagerHostVC.swift \
  Pharos/Windows/Manager/*.swift \
  Pharos/Settings/Furniture/SettingsSymbolBadge.swift \
  PharosTests/TagManagerWindowTests.swift \
  PharosTests/main.swift
/tmp/tag-manager-window-tests
