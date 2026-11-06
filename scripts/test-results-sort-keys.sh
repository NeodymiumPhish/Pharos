#!/bin/bash
# Standalone test runner for ResultsSortKeys. Pure Foundation, no AppKit.
# SORT_BENCH=1 also prints old vs new sort times for 200,000 rows.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -O -o /tmp/results-sort-keys-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsSortKeys.swift \
  PharosTests/ResultsSortKeysTests.swift \
  PharosTests/main.swift
/tmp/results-sort-keys-tests
