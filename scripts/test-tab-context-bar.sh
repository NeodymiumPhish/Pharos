#!/bin/bash
# Standalone test runner for TabContextBar — real AppKit in an off-screen
# window, no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-tab-context-bar-tests \
  Pharos/Views/TabContextBar.swift \
  Pharos/Views/ConnectionMenuArt.swift \
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

# The row's right-click items reach the content controller BY NAME
# (NSSelectorFromString), so a rename there would leave them dead and greyed.
for action in $(grep -o 'NSSelectorFromString("[A-Za-z]*:")' Pharos/Views/TabContextBar.swift | sed 's/.*("\([A-Za-z]*\):")/\1/'); do
    if grep -q "@objc func $action(" Pharos/ViewControllers/ContentViewController.swift; then
        echo "PASS ContentViewController answers $action:"
    else
        echo "FAIL ContentViewController has no $action:"; exit 1
    fi
done
