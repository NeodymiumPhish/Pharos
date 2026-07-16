#!/bin/bash
# Standalone test runner for TableDDL — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
swiftc -o /tmp/table-ddl-tests \
  Pharos/Models/TableDDL.swift \
  PharosTests/TableDDLTests.swift \
  "$TMPMAIN"
/tmp/table-ddl-tests
