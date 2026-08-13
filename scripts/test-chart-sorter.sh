#!/bin/bash
# Standalone test runner for ChartSorter — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/chart-sorter-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/ChartConfig.swift \
  Pharos/Models/Charts/ColumnClassifier.swift \
  Pharos/Models/Charts/ValueCoercion.swift \
  Pharos/Models/Charts/DrillKey.swift \
  Pharos/Models/Charts/ChartData.swift \
  Pharos/Models/Charts/ChartSorter.swift \
  PharosTests/ChartSorterTests.swift \
  PharosTests/main.swift
/tmp/chart-sorter-tests
