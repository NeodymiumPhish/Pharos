#!/bin/bash
# Standalone test runner for FilterValueCount + FilterValueSort — no Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
swiftc -o /tmp/filter-value-counts-tests \
  Pharos/ViewControllers/ResultsGrid/FilterValueCount.swift \
  Pharos/ViewControllers/ResultsGrid/FilterValueSort.swift \
  PharosTests/FilterValueCountsTests.swift \
  "$TMPMAIN"
/tmp/filter-value-counts-tests
