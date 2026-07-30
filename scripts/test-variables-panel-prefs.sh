#!/bin/bash
# Standalone test runner for VariablesPanelPrefs — no Xcode project involvement.
# Covers the preference logic only (first-run defaulting, stickiness, clamping);
# whether the panel actually appears is verified by running the app.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/variables-panel-prefs-tests \
  Pharos/Core/VariablesPanelPrefs.swift \
  PharosTests/VariablesPanelPrefsTests.swift \
  PharosTests/main.swift
/tmp/variables-panel-prefs-tests
