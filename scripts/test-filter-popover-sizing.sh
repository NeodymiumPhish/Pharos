#!/bin/bash
# Standalone test runner for FilterPopoverSizing — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
swiftc -o /tmp/filter-popover-sizing-tests \
  Pharos/ViewControllers/ResultsGrid/FilterPopoverSizing.swift \
  PharosTests/FilterPopoverSizingTests.swift \
  "$TMPMAIN"
/tmp/filter-popover-sizing-tests
