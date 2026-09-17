#!/bin/bash
# Standalone test runner for SchemaPopUpButton: activation through the hook
# (click, Space, Return; not when disabled) and the pressed look while its
# popover is up.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/schema-popup-button-tests \
  Pharos/Views/SchemaPopUpButton.swift \
  PharosTests/SchemaPopUpButtonTests.swift \
  PharosTests/main.swift
/tmp/schema-popup-button-tests
