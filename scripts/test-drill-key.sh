#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/drill-key-tests \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/DrillKey.swift \
  PharosTests/DrillKeyTests.swift \
  PharosTests/main.swift
/tmp/drill-key-tests
