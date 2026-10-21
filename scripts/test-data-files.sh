#!/bin/bash
# Standalone test runner for DataFiles: what a data file is (CSV, JSON,
# Parquet, Excel …) and what goes into a DuckDB card for it.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t data-files-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Core/DataFiles.swift \
  PharosTests/DataFilesTests.swift \
  PharosTests/main.swift
"$BIN"
