#!/bin/bash
# Standalone test runner for AuthoredLabelSanitizer and the NSTextField rewrite
# that applies it as a name is typed.
#
# No caller is compiled in. TableDDLSheet.swift drags the DDL model and the
# clone FFI behind it, and TagManagerSheet.swift brings the whole tag stack;
# each is exercised by its own suite. What every caller uses is this
# extension, and this suite drives it through a real field editor.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/authored-label-sanitizer-tests \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Views/NSTextField+AuthoredLabel.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/SanitiseNotice.swift \
  Pharos/Views/Toast.swift \
  PharosTests/AuthoredLabelSanitizerTests.swift \
  PharosTests/main.swift
/tmp/authored-label-sanitizer-tests
