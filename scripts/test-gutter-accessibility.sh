#!/bin/bash
# Standalone test runner for LineNumberGutter's accessibility container — no
# Xcode project involvement. Same file list as test-variable-detail-vc.sh's
# gutter dependencies, plus AccessibilityDisplay (the gutter reads
# "Differentiate without colour" when it paints an error marker).
#
# The binary name is unique to this suite: every test-*.sh writes a fixed path,
# and two suites sharing one would clobber each other when run concurrently.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/gutter-accessibility-tests \
  Pharos/Editor/LineNumberGutter.swift \
  Pharos/Views/MarkerShape.swift \
  Pharos/Core/AccessibilityDisplay.swift \
  Pharos/Core/PulseClock.swift \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Editor/SQLSegmentParser.swift \
  Pharos/Editor/SQLFoldingParser.swift \
  PharosTests/GutterAccessibilityTests.swift \
  PharosTests/main.swift
/tmp/gutter-accessibility-tests
