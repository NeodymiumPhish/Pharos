#!/bin/bash
# Standalone test runner for PopupValueMenu. Pure AppKit menu objects.
# DisplayEscape comes along because `populate` escapes each row's title.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/popup-value-menu-tests \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/PopupValueMenu.swift \
  PharosTests/PopupValueMenuTests.swift \
  PharosTests/main.swift
/tmp/popup-value-menu-tests
