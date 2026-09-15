#!/bin/bash
# Standalone test runner for the rule that decides whether one cell of a
# result may be edited — the five-point rule of D5, posed one fault at a time
# against fixtures. Pure Foundation, no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/cell-editability-tests \
  Pharos/Models/PendingCellEdits.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/CellEditabilityTests.swift \
  PharosTests/main.swift
/tmp/cell-editability-tests
