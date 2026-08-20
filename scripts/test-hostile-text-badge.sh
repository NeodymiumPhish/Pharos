#!/bin/bash
# Standalone test runner for HostileTextBadge. Real AppKit views, no window.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/hostile-text-badge-tests \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Views/HostileTextBadge.swift \
  PharosTests/HostileTextBadgeTests.swift \
  PharosTests/main.swift
/tmp/hostile-text-badge-tests
