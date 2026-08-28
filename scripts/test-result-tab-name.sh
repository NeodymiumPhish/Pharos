#!/bin/bash
# Standalone test runner for ResultTabName — no Xcode project involvement.
# Pure Foundation: the rename rule and the authored-label sanitiser it delegates
# to, nothing else.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/result-tab-name-tests \
  Pharos/Core/ResultTabName.swift \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  PharosTests/ResultTabNameTests.swift \
  PharosTests/main.swift
/tmp/result-tab-name-tests
