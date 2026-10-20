#!/bin/bash
# Standalone test runner for DuckDBFiles: which connection record opens a
# DuckDB file (the File menu, Finder, the Dock, Open Recent).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t duckdb-files-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Models/Connection.swift \
  Pharos/Core/DuckDBFiles.swift \
  PharosTests/DuckDBFilesTests.swift \
  PharosTests/main.swift
"$BIN"
