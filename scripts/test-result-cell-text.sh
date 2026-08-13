#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/result-cell-text-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/ViewControllers/ResultsGrid/ResultCellText.swift \
  PharosTests/ResultCellTextTests.swift \
  PharosTests/main.swift
/tmp/result-cell-text-tests
