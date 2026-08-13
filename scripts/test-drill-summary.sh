#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/drill-summary-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/DrillKey.swift \
  Pharos/Utilities/BlanksSentinel.swift \
  Pharos/Models/Charts/DrillSummary.swift \
  PharosTests/DrillSummaryTests.swift \
  PharosTests/main.swift
/tmp/drill-summary-tests
