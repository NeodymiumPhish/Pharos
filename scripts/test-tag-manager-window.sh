#!/bin/bash
# Standalone test runner for TagManagerHostVC: the Tag Manager window's content — it
# opens with no tags, stays open after a save on a fresh sheet, closes on Cancel,
# follows the store only when it has no edits, and asks before discarding them.
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
  Pharos/Sheets/TagAddValuesSheet.swift \
  Pharos/Core/TagValueImport.swift \
  Pharos/Sheets/TagManagerHostVC.swift \
  PharosTests/TagManagerWindowTests.swift \
  PharosTests/main.swift
/tmp/tag-manager-window-tests
