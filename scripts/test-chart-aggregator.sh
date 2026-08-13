#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/chart-aggregator-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/ChartConfig.swift \
  Pharos/Models/Charts/ColumnClassifier.swift \
  Pharos/Models/Charts/ValueCoercion.swift \
  Pharos/Models/Charts/DrillKey.swift \
  Pharos/Models/Charts/ChartData.swift \
  Pharos/Models/Charts/ChartAggregator.swift \
  PharosTests/ChartAggregatorTests.swift \
  PharosTests/main.swift
/tmp/chart-aggregator-tests
