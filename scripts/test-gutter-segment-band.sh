#!/bin/bash
# Standalone test runner for the gutter's segment band — the statement colour
# drawn BEHIND the line numbers, the hover cross-fade, and the run gesture.
#
# Real AppKit, headless: the gutter is hosted in a never-shown NSWindow so the
# layout manager lays text out, and the legibility check renders the view
# offscreen with cacheDisplay (live window capture is blocked — tasks/lessons.md).
#
# The binary name is unique to this suite: every test-*.sh writes a fixed path,
# and two suites sharing one would clobber each other when run concurrently.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-gutter-segment-band-tests \
  Pharos/Editor/LineNumberGutter.swift \
  Pharos/Views/MarkerShape.swift \
  Pharos/Core/AccessibilityDisplay.swift \
  Pharos/Core/PulseClock.swift \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Editor/SQLSegmentParser.swift \
  Pharos/Editor/SQLFoldingParser.swift \
  PharosTests/GutterSegmentBandTests.swift \
  PharosTests/main.swift
/tmp/pharos-gutter-segment-band-tests
