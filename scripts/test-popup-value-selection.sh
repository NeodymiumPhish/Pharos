#!/bin/bash
# Standalone test runner for PopupValueSelection. Pure AppKit menu objects.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/popup-value-selection-tests \
  Pharos/Core/PopupValueSelection.swift \
  PharosTests/PopupValueSelectionTests.swift \
  PharosTests/main.swift
/tmp/popup-value-selection-tests
