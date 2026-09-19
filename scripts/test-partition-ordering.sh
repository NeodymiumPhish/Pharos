#!/bin/bash
# Standalone test runner for PartitionOrdering — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
# `Settings.swift` comes along because `PartitionSortMode` lives there, beside
# every other type `AppSettings` names; `ChartPalette.swift` because
# `ChartSettings` reads its default palette from it.
swiftc -o /tmp/partition-ordering-tests \
  Pharos/Models/Schema.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Models/PartitionOrdering.swift \
  PharosTests/PartitionOrderingTests.swift \
  "$TMPMAIN"
/tmp/partition-ordering-tests
