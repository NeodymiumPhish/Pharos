#!/bin/bash
# Standalone test runner for TaggedRowView. Real AppKit, headless.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tagged-row-view-tests \
  Pharos/ViewControllers/ResultsGrid/TaggedRowView.swift \
  PharosTests/TaggedRowViewTests.swift \
  PharosTests/main.swift
/tmp/tagged-row-view-tests
