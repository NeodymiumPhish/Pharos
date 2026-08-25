#!/bin/bash
# Standalone test runner for TagConditionRowView. Uses real AppKit through a
# headless NSWindow, like scripts/test-tag-removal-sheet.sh.
#
# TagPredicate and its dependencies are compiled in because the row validates
# through TagConditionEditor, which delegates its refusals to the real matcher —
# a stand-in could accept a condition that saves but never matches.
#
# No TagStore: it is @MainActor and reaches the Keychain through the FFI, which
# would hang a headless run. The row never touches it.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-condition-row-view-tests \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/PopupValueMenu.swift \
  Pharos/Core/TagConditionEditor.swift \
  Pharos/Core/TagConditionKind.swift \
  Pharos/Core/TagFamilyLabel.swift \
  Pharos/Core/TagGlob.swift \
  Pharos/Core/TagPredicate.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Models/Tag.swift \
  Pharos/Views/HostileTextBadge.swift \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  Pharos/Views/TagConditionRowView.swift \
  PharosTests/TagConditionRowViewTests.swift \
  PharosTests/main.swift
/tmp/tag-condition-row-view-tests
