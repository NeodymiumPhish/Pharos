#!/bin/bash
# Standalone test runner for GridSelectionValidity. The rule itself is pure
# Foundation; the test file also pins the AppKit reloadData/selection fact the
# rule compensates for, so this one links AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/grid-selection-validity-tests \
  Pharos/Core/GridSelectionValidity.swift \
  PharosTests/GridSelectionValidityTests.swift \
  PharosTests/main.swift
/tmp/grid-selection-validity-tests
