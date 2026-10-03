#!/bin/bash
# Standalone test runner for SQLSummary — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-sql-summary-tests \
  Pharos/Core/SQLSummary.swift \
  PharosTests/SQLSummaryTests.swift \
  PharosTests/main.swift
/tmp/pharos-sql-summary-tests
