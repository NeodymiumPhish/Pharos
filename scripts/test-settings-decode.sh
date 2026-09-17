#!/bin/bash
# Standalone test runner for AppSettings' decode of the blob pharos-core sends:
# every Swift field must have its camelCase key on the wire, or the synthesized
# decoder throws at launch. ChartPalette comes along for the charts default.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/settings-decode-tests \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  PharosTests/SettingsDecodeTests.swift \
  PharosTests/main.swift
/tmp/settings-decode-tests
