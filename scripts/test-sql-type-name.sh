#!/bin/bash
# Standalone test runner for SQLTypeName: DuckDB's type names classify like
# their PostgreSQL equivalents at every type-name site; PostgreSQL's are unchanged.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t sql-type-name-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Utilities/SQLTypeName.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/Models/ColumnTypeIcon.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ValueCoercion.swift \
  Pharos/Models/Charts/ColumnClassifier.swift \
  PharosTests/SQLTypeNameTests.swift \
  PharosTests/main.swift
"$BIN"
