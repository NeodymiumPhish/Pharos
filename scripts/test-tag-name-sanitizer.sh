#!/bin/bash
# Standalone test runner for TagNameSanitizer and the NSTextField rewrite that
# applies it as a name is typed.
#
# TagSheet.swift and TagManageSheet.swift are deliberately NOT compiled in:
# both reach TagStore.shared, which is @MainActor (which main.swift's
# nonisolated runTests() cannot call into) and reaches the Keychain through the
# FFI, which would hang a headless run. What they call is this extension, and
# this suite drives it through a real field editor.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-name-sanitizer-tests \
  Pharos/Core/TagNameSanitizer.swift \
  Pharos/Views/NSTextField+TagName.swift \
  PharosTests/TagNameSanitizerTests.swift \
  PharosTests/main.swift
/tmp/tag-name-sanitizer-tests
