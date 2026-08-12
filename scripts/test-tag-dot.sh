#!/bin/bash
# Standalone test runner for TagDot. Real AppKit, headless.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-dot-tests \
  Pharos/ViewControllers/ResultsGrid/TagDot.swift \
  PharosTests/TagDotTests.swift \
  PharosTests/main.swift
/tmp/tag-dot-tests
