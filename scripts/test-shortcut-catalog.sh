#!/bin/bash
# Standalone test runner for ShortcutCatalog: the menu-bar walk that feeds the
# read-only Shortcuts pane, how a key equivalent is rendered (an upper-case
# key IS Shift), and the search filter.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/shortcut-catalog-tests \
  Pharos/Settings/ShortcutCatalog.swift \
  PharosTests/ShortcutCatalogTests.swift \
  PharosTests/main.swift
/tmp/shortcut-catalog-tests
