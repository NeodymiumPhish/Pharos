#!/bin/bash
# Standalone test runner for AuthoredLabelSanitizer and the NSTextField rewrite
# that applies it as a name is typed.
#
# No caller is compiled in. TagSheet.swift and TagManageSheet.swift reach
# TagStore.shared, which is @MainActor (which main.swift's nonisolated
# runTests() cannot call into) and reaches the Keychain through the FFI, which
# would hang a headless run; TableDDLSheet.swift — the third caller — drags the
# DDL model and the clone FFI behind it. What every caller uses is this
# extension, and this suite drives it through a real field editor.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/authored-label-sanitizer-tests \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Views/NSTextField+AuthoredLabel.swift \
  PharosTests/AuthoredLabelSanitizerTests.swift \
  PharosTests/main.swift
/tmp/authored-label-sanitizer-tests
