#!/bin/bash
# Standalone test runner for ChartPalette — no Xcode project involvement.
# Only the pure/Foundation-only half is tested; the SwiftUI Color bridge
# (ChartPalette+Color.swift) is build-gated and manually verified.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/chart-palette-tests \
  Pharos/Models/Charts/ChartPalette.swift \
  PharosTests/ChartPaletteTests.swift \
  PharosTests/main.swift
/tmp/chart-palette-tests
