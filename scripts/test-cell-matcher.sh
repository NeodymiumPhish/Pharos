#!/bin/bash
# Standalone test runner for CellMatcher — the one rule the results Find field
# matches a cell by (Settings ▸ Results ▸ Find). Foundation only; the settings
# model comes along for `FindMode`, and ChartPalette behind it for the charts
# default.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/cell-matcher-tests \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/ViewControllers/ResultsGrid/CellMatcher.swift \
  PharosTests/CellMatcherTests.swift \
  PharosTests/main.swift
/tmp/cell-matcher-tests
