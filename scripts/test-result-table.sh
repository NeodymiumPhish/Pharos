#!/bin/bash
# Standalone test runner for ResultTable (the PRB1 columnar block). Pure Foundation.
# TABLE_BENCH=1 also prints size and decode time for 200,000 x 20.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -O -o /tmp/result-table-tests \
  Pharos/Models/ResultTable.swift \
  PharosTests/ResultTableTests.swift \
  PharosTests/main.swift
/tmp/result-table-tests
