#!/bin/bash
# Standalone test runner for ResultTabsPanelVC — no Xcode project involvement.
# The panel is a pure view layer, so it compiles here without the PharosCore
# FFI bridge; the suite hosts it in a never-shown NSWindow.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/result-tabs-panel-vc-tests \
  Pharos/ViewControllers/ResultTabsPanelVC.swift \
  Pharos/Views/ResultTabRowCell.swift \
  Pharos/Core/ResultTabRowText.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/HistoryRowText.swift \
  PharosTests/ResultTabsPanelVCTests.swift \
  PharosTests/main.swift
/tmp/result-tabs-panel-vc-tests
