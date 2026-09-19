#!/bin/bash
# Standalone test runner for the Settings window's pure navigation types:
# SettingsPaneID/Spec, the registry, the back/forward history and the
# remembered pane. No FFI, no view controllers.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/settings-navigation-tests \
  Pharos/Settings/SettingsPaneSpec.swift \
  Pharos/Settings/SettingsPaneRegistry.swift \
  Pharos/Settings/SettingsNavigationHistory.swift \
  Pharos/Settings/SettingsPanePrefs.swift \
  PharosTests/SettingsNavigationTests.swift \
  PharosTests/main.swift
/tmp/settings-navigation-tests
