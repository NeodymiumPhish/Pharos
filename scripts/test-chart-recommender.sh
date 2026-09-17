#!/bin/bash
# Standalone test runner for ChartRecommender — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/chart-recommender-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/ChartConfig.swift \
  Pharos/Models/Charts/ChartData.swift \
  Pharos/Models/Charts/DrillKey.swift \
  Pharos/Models/Charts/ColumnClassifier.swift \
  Pharos/Models/Charts/ValueCoercion.swift \
  Pharos/Models/Charts/ColumnProfile.swift \
  Pharos/Models/Charts/ChartRoleEligibility.swift \
  Pharos/Models/Charts/ChartAxisTitles.swift \
  Pharos/Models/Charts/ChartRecommender.swift \
  PharosTests/ChartRecommenderTests.swift \
  PharosTests/main.swift
/tmp/chart-recommender-tests
