#!/bin/bash
# Standalone test runner for ResultValueFormatter — the parser behind
# Settings ▸ Results ▸ Formatting. Pure Foundation, no AppKit: the settings
# model comes along for `ResultDateStyle` / `ResultNumberStyle`, and
# ChartPalette behind it for the charts default.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/result-value-formatter-tests \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Core/ResultValueFormatter.swift \
  PharosTests/ResultValueFormatterTests.swift \
  PharosTests/main.swift
/tmp/result-value-formatter-tests
