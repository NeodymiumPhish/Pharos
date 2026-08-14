#!/bin/bash
# Standalone test runner for TagRemovalSheet. Uses real AppKit through a
# headless NSWindow, like scripts/test-query-error-sheet.sh.
#
# TagStore.swift is deliberately NOT compiled in: it is @MainActor (which
# main.swift's nonisolated runTests() cannot call into) and it reaches the
# Keychain through the FFI, which would hang a headless run. The sheet commits
# through TagTupleRemoving, which sits in its own dependency-free file (so that
# scripts/test-tag-store.sh can compile the store's conformance without pulling
# in this AppKit sheet), and the test file supplies its own conformer — so no
# store, no staticlib, no prompt. The real
# TagStore conforms in TagStore.swift, so a signature change fails the app
# build rather than passing here against something that no longer exists.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-removal-sheet-tests \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/TagTupleMatcher.swift \
  Pharos/Core/TagPalette.swift \
  Pharos/Core/TagRemovalModel.swift \
  Pharos/Core/TagTupleRemoving.swift \
  Pharos/Models/Tag.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Sheets/TagRemovalSheet.swift \
  PharosTests/TagRemovalSheetTests.swift \
  PharosTests/main.swift
/tmp/tag-removal-sheet-tests
