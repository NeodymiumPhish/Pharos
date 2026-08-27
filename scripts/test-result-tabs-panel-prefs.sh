#!/bin/bash
# Standalone test runner for ResultTabsPanelPrefs — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/result-tabs-panel-prefs-tests \
  Pharos/Core/ResultTabsPanelPrefs.swift \
  PharosTests/ResultTabsPanelPrefsTests.swift \
  PharosTests/main.swift
/tmp/result-tabs-panel-prefs-tests
