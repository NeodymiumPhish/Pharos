#!/bin/bash
# Standalone test runner for DuckDBCloseRule: a DuckDB file closes when no
# tab uses it (not in-memory, not connect-on-launch, not while quitting).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t duckdb-close-rule-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Models/Connection.swift \
  Pharos/Core/DuckDBFiles.swift \
  Pharos/Core/DataFiles.swift \
  Pharos/Core/DuckDBCloseRule.swift \
  PharosTests/DuckDBCloseRuleTests.swift \
  PharosTests/main.swift
"$BIN"
