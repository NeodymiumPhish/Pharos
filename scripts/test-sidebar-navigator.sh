#!/bin/bash
# Standalone test runner for the sidebar's navigator selector, its bottom
# filter bar, and the state behind both. Real AppKit, headless, but the
# selector's buttons are hosted in an offscreen NSWindow: `performClick` needs
# a window to send its action.
#
# The view controllers are excluded — they pull in the PharosCore FFI bridge,
# which cannot link in a plain swiftc binary. Only the two views and the
# preference/state types are compiled.
#
# The binary name is unique to this suite: every test-*.sh writes a fixed path,
# and two suites sharing one would clobber each other when run concurrently.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-sidebar-navigator-tests \
  Pharos/Views/NavigatorSelector.swift \
  Pharos/Views/SidebarFilterBar.swift \
  Pharos/Core/SidebarNavigatorPrefs.swift \
  PharosTests/SidebarNavigatorTests.swift \
  PharosTests/main.swift
/tmp/pharos-sidebar-navigator-tests
