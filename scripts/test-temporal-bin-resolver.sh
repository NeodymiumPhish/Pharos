#!/bin/bash
# Standalone test runner for TemporalBinResolver (auto time buckets from the span).
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/temporal-bin-resolver-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/ChartConfig.swift \
  Pharos/Models/Charts/ChartData.swift \
  Pharos/Models/Charts/DrillKey.swift \
  Pharos/Models/Charts/ColumnClassifier.swift \
  Pharos/Models/Charts/ValueCoercion.swift \
  Pharos/Models/Charts/ChartAggregator.swift \
  Pharos/Models/Charts/TemporalBinResolver.swift \
  PharosTests/TemporalBinResolverTests.swift \
  PharosTests/main.swift
/tmp/temporal-bin-resolver-tests
