#!/bin/bash
# Standalone test runner for PartitionDisplay.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
# Schema.swift comes along because PartitionDisplay names PartitionStrategy
# and PartitionMechanism, and Settings.swift + ChartPalette come along
# because Schema.swift names CsvDialect and ImportErrorPolicy, which live
# with the settings.
swiftc -o /tmp/partition-display-tests \
  Pharos/Models/PartitionDisplay.swift \
  Pharos/Models/Schema.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  PharosTests/PartitionDisplayTests.swift \
  "$TMPMAIN"
/tmp/partition-display-tests
