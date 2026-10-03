#!/bin/bash
# Standalone test runner for TabContextBar — real AppKit in an off-screen
# window, no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-tab-context-bar-tests \
  Pharos/Views/TabContextBar.swift \
  Pharos/Views/TabConnectionDot.swift \
  Pharos/Views/SchemaPopUpButton.swift \
  Pharos/Core/PulseClock.swift \
  Pharos/Core/TabContextState.swift \
  Pharos/Core/TabSessionBannerModel.swift \
  Pharos/Models/TabSession.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/RowEdit.swift \
  Pharos/Models/Connection.swift \
  PharosTests/TabContextBarTests.swift \
  PharosTests/main.swift
/tmp/pharos-tab-context-bar-tests
