#!/bin/bash
# Standalone test runner for the two pure judgements about a failed query:
# whether it belongs in Query History (a server answer does, a client-side
# refusal does not) and whether it means the connection itself is gone (a
# statement timeout does NOT).
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/query-failure-classification-tests \
  Pharos/Core/HistoryFailureFilter.swift \
  Pharos/Core/ConnectionLossClassifier.swift \
  PharosTests/HistoryFailureFilterTests.swift \
  PharosTests/main.swift
/tmp/query-failure-classification-tests
