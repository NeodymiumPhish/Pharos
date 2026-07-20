#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/drill-coverage-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/DrillKey.swift \
  Pharos/Utilities/BlanksSentinel.swift \
  Pharos/Models/Charts/DrillMerge.swift \
  Pharos/Models/Charts/DrillCoverage.swift \
  PharosTests/DrillCoverageTests.swift \
  PharosTests/main.swift
/tmp/drill-coverage-tests
