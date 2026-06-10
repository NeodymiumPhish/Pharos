#!/bin/bash
# Standalone test runner for SQLListFormatter — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/sql-list-formatter-tests \
  Pharos/Editor/SQLListFormatter.swift \
  PharosTests/SQLListFormatterTests.swift \
  PharosTests/main.swift
/tmp/sql-list-formatter-tests
