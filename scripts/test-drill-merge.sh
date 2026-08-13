#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/drill-merge-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/DrillKey.swift \
  Pharos/Utilities/BlanksSentinel.swift \
  Pharos/Models/Charts/DrillMerge.swift \
  PharosTests/DrillMergeTests.swift \
  PharosTests/main.swift
/tmp/drill-merge-tests
