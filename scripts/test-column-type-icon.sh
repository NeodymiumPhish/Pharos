#!/bin/bash
# Standalone test runner for ColumnTypeIcon — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
swiftc -o /tmp/column-type-icon-tests \
  Pharos/Models/ColumnTypeIcon.swift \
  PharosTests/ColumnTypeIconTests.swift \
  "$TMPMAIN"
/tmp/column-type-icon-tests
