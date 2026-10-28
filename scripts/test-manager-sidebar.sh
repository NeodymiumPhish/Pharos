#!/bin/bash
# Standalone test runner for the shared manager shell (Pharos/Windows/Manager):
# the sidebar's rows, selection, filter, Delete key, context menu and reorder;
# the cell's accessibility identifier and its selected / unselected colours,
# rendered and measured in Light and Dark; the split view's set-up and the
# toolbar on a UtilityWindow. Real AppKit in offscreen windows.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/manager-sidebar-tests \
  Pharos/Windows/Manager/*.swift \
  Pharos/Windows/UtilityWindow.swift \
  Pharos/Settings/Furniture/SettingsSymbolBadge.swift \
  Pharos/Settings/Furniture/SettingsMetrics.swift \
  PharosTests/ManagerSidebarTests.swift \
  PharosTests/main.swift
/tmp/manager-sidebar-tests
