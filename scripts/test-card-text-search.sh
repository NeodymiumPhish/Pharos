#!/bin/bash
# Standalone test runner for CardTextMatcher / CardTextEdits — the card
# editor's Find and Replace and Change Variable. Foundation only; the settings
# model comes along for `FindMode` (and ChartPalette behind it), and the
# variable files for `VariableSubstitutor.tokens`.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/card-text-search-tests \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Models/QueryVariable.swift \
  Pharos/Core/VariableSubstitutor.swift \
  Pharos/Core/VariableValueRules.swift \
  Pharos/Core/Cards/CardTextSearch.swift \
  PharosTests/CardTextSearchTests.swift \
  PharosTests/main.swift
/tmp/card-text-search-tests
