#!/bin/bash
# Standalone test runner for TagManagerSheet. Uses real AppKit through a
# headless NSWindow, like scripts/test-tag-rule-grid-view.sh.
#
# TagManagerCommitting.swift IS compiled in — do not copy the file list from
# scripts/test-tag-manager-model.sh, which does not need it. The sheet commits
# through that protocol and the test file supplies the only conformer, which is
# what keeps TagStore out of the binary: it is @MainActor and reaches the
# Keychain through the FFI, which would hang a headless run.
#
# The whole condition stack comes along because the sheet hosts the real rule
# grid, which hosts real condition rows, which validate through
# TagConditionEditor and therefore through the real matcher. The authored-label
# sanitiser and Toast come along because the NAME field is sanitised as it is
# typed, and the sanitiser's notice path references Toast.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-manager-sheet-tests \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/PopupValueMenu.swift \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Core/RuleKey.swift \
  Pharos/Core/SanitiseNotice.swift \
  Pharos/Core/TagConditionEditor.swift \
  Pharos/Core/TagConditionKind.swift \
  Pharos/Core/TagFamilyLabel.swift \
  Pharos/Core/TagGlob.swift \
  Pharos/Core/TagManagerCommitting.swift \
  Pharos/Core/TagManagerModel.swift \
  Pharos/Core/TagPalette.swift \
  Pharos/Core/TagPredicate.swift \
  Pharos/Core/TagRuleMatcher.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Tag.swift \
  Pharos/Views/HostileTextBadge.swift \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  Pharos/Views/NSTextField+AuthoredLabel.swift \
  Pharos/Views/TagConditionRowView.swift \
  Pharos/Views/TagRuleGridView.swift \
  Pharos/Views/Toast.swift \
  Pharos/Sheets/TagManagerSheet.swift \
  PharosTests/TagManagerSheetTests.swift \
  PharosTests/main.swift
/tmp/tag-manager-sheet-tests
