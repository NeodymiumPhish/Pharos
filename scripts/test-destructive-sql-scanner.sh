#!/bin/bash
# Standalone test runner for DestructiveSQLScanner — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/destructive-sql-scanner-tests \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Utilities/DestructiveSQLScanner.swift \
  PharosTests/DestructiveSQLScannerTests.swift \
  PharosTests/main.swift
/tmp/destructive-sql-scanner-tests
