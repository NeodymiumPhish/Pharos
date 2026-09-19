#!/bin/bash
# Standalone test runner for SettingsMigration: the one-way move of the
# preferences that predate the Settings window out of UserDefaults and into
# AppSettings. Foundation and the settings model only — no AppKit, no
# AppStateManager — which is why that file is written the way it is.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/settings-migration-tests \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Settings/SettingsMigration.swift \
  PharosTests/SettingsMigrationTests.swift \
  PharosTests/main.swift
/tmp/settings-migration-tests
