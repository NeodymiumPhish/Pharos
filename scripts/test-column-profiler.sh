#!/bin/bash
# Standalone test runner for ColumnProfiler and ChartRoleEligibility.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/column-profiler-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/ColumnClassifier.swift \
  Pharos/Models/Charts/ValueCoercion.swift \
  Pharos/Models/Charts/ColumnProfile.swift \
  Pharos/Models/Charts/ChartRoleEligibility.swift \
  PharosTests/ColumnProfilerTests.swift \
  PharosTests/main.swift
/tmp/column-profiler-tests
