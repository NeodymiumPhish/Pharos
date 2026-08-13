#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/sql-pushdown-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/ChartConfig.swift \
  Pharos/Models/Charts/ColumnClassifier.swift \
  Pharos/Models/Charts/ValueCoercion.swift \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLSegmentParser.swift \
  Pharos/Models/Charts/PushdownQuery.swift \
  Pharos/Models/Charts/SqlPushdownGenerator.swift \
  PharosTests/SqlPushdownGeneratorTests.swift \
  PharosTests/main.swift
/tmp/sql-pushdown-tests
