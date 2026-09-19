#!/bin/bash
# Standalone test runner for the Settings furniture kit
# (Pharos/Settings/Furniture). Real AppKit: rows are laid out in a hosted
# window and measured, and the group box and badge are rendered offscreen so
# the painted colours are compared, not assumed.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/settings-furniture-tests \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  Pharos/Settings/Furniture/*.swift \
  PharosTests/SettingsFurnitureTests.swift \
  PharosTests/main.swift
/tmp/settings-furniture-tests
