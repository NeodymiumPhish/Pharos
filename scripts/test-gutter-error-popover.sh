#!/bin/bash
# Standalone test runner for the gutter's error popover — the message shown
# beside the marker and its "Go to Error" button. Same file list as
# scripts/test-gutter-accessibility.sh; the popover lives in LineNumberGutter.
#
# The binary name is unique to this suite: every test-*.sh writes a fixed path,
# and two suites sharing one would clobber each other when run concurrently.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/gutter-error-popover-tests \
  Pharos/Editor/LineNumberGutter.swift \
  Pharos/Core/AccessibilityDisplay.swift \
  Pharos/Core/PulseClock.swift \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Editor/SQLSegmentParser.swift \
  Pharos/Editor/SQLFoldingParser.swift \
  PharosTests/GutterErrorPopoverTests.swift \
  PharosTests/main.swift
/tmp/gutter-error-popover-tests
