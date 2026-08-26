#!/bin/bash
# Standalone test runner for TagRuleGridView. Uses real AppKit through a
# headless NSWindow, like scripts/test-tag-condition-row-view.sh.
#
# TagManagerModel is compiled in because `EditableTag` and `EditableRule` live
# there, and because one assertion deletes a rule through the REAL model before
# re-rendering — a hand-rolled stand-in could keep an index the model would not.
# That drags in RuleKey and RowFingerprint, which the model's commit derivation
# needs.
#
# TagPredicate and its dependencies come along because each condition row
# validates through TagConditionEditor, which delegates its refusals to the real
# matcher.
#
# No TagStore: it is @MainActor and reaches the Keychain through the FFI, which
# would hang a headless run. The grid never touches it.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-rule-grid-view-tests \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/PopupValueMenu.swift \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Core/RuleKey.swift \
  Pharos/Core/TagConditionEditor.swift \
  Pharos/Core/TagConditionKind.swift \
  Pharos/Core/TagFamilyLabel.swift \
  Pharos/Core/TagGlob.swift \
  Pharos/Core/TagCapture.swift \
  Pharos/Core/TagDraft.swift \
  Pharos/Core/TagManagerModel.swift \
  Pharos/Core/TagPredicate.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Models/Tag.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Views/HostileTextBadge.swift \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  Pharos/Views/TagConditionRowView.swift \
  Pharos/Views/TagRuleGridView.swift \
  PharosTests/TagRuleGridViewTests.swift \
  PharosTests/main.swift
/tmp/tag-rule-grid-view-tests
