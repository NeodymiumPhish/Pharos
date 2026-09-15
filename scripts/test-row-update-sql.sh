#!/bin/bash
# Standalone test runner for the UPDATE statements the review sheet shows and
# the `RowUpdateRequest` the core is handed. Pure Foundation — no AppKit, no
# FFI: the request type and the builder are both plain value code so this
# suite links the REAL production ones.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/row-update-sql-tests \
  Pharos/Core/CountedNounText.swift \
  Pharos/Core/RowUpdateSQLBuilder.swift \
  Pharos/Models/PendingCellEdits.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/RowEdit.swift \
  Pharos/Utilities/SqlIdentifierQuoting.swift \
  PharosTests/RowUpdateSQLTests.swift \
  PharosTests/main.swift
/tmp/row-update-sql-tests
