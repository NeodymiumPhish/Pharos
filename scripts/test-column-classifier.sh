#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/column-classifier-tests \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/ColumnClassifier.swift \
  Pharos/Models/Charts/ValueCoercion.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/ColumnClassifierTests.swift \
  PharosTests/main.swift
/tmp/column-classifier-tests
