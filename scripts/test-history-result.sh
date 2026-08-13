#!/bin/bash
# Standalone test runner for QueryResult.fromHistory. Pure Foundation, no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/history-result-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/QueryHistory.swift \
  PharosTests/HistoryResultTests.swift \
  PharosTests/main.swift
/tmp/history-result-tests
