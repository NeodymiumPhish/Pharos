#!/bin/bash
# Standalone test runner for PartitionDisplay.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
swiftc -o /tmp/partition-display-tests \
  Pharos/Models/PartitionDisplay.swift \
  PharosTests/PartitionDisplayTests.swift \
  "$TMPMAIN"
/tmp/partition-display-tests
