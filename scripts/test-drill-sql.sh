#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/drill-sql-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/DrillKey.swift \
  Pharos/Utilities/BlanksSentinel.swift \
  Pharos/Models/Charts/DrillSqlTranslator.swift \
  PharosTests/DrillSqlTranslatorTests.swift \
  PharosTests/main.swift
/tmp/drill-sql-tests
