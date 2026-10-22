#!/bin/bash
# Standalone test runner for TabBarMenu / MainWindow: "Rename Tab…" in the
# native tab bar's right-click menu. Real AppKit tab groups off-screen; every
# click is an NSEvent sent to the window in-process, never posted to the screen.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-tab-bar-menu-tests \
  Pharos/Windows/MainWindow.swift \
  PharosTests/TabBarMenuTests.swift \
  PharosTests/main.swift
/tmp/pharos-tab-bar-menu-tests
