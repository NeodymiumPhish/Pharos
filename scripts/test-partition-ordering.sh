#!/bin/bash
# Standalone test runner for PartitionOrdering — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
swiftc -o /tmp/partition-ordering-tests \
  Pharos/Models/Schema.swift \
  Pharos/Models/PartitionOrdering.swift \
  PharosTests/PartitionOrderingTests.swift \
  "$TMPMAIN"
/tmp/partition-ordering-tests
