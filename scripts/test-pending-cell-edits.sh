#!/bin/bash
# Standalone test runner for the pending cell-edit model — no Xcode project
# involvement. `PendingCellEdits.swift` is pure Foundation on purpose, so the
# suite links the REAL production type rather than a copy of it.
#
# QueryResult.swift comes along because `CellEditability`, which shares the
# file, reads ColumnDef / RowIdentity / KeySet.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pending-cell-edits-tests \
  Pharos/Models/PendingCellEdits.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/PendingCellEditsTests.swift \
  PharosTests/main.swift
/tmp/pending-cell-edits-tests
