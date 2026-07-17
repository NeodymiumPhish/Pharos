#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/drill-translator-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/DrillKey.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/Utilities/ColumnFilter.swift \
  Pharos/Models/Charts/DrillTranslator.swift \
  PharosTests/DrillTranslatorTests.swift \
  PharosTests/main.swift
/tmp/drill-translator-tests
