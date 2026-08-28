#!/bin/bash
# Standalone test runner for ResultTabContextMenu — no Xcode project
# involvement. The builder carries no model type, so it compiles alone.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/result-tab-context-menu-tests \
  Pharos/Views/ResultTabContextMenu.swift \
  PharosTests/ResultTabContextMenuTests.swift \
  PharosTests/main.swift
/tmp/result-tab-context-menu-tests
