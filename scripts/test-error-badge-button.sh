#!/bin/bash
# Standalone test runner for ErrorBadgeButton. Uses real AppKit through a
# headless NSWindow, like scripts/test-variable-row-layout.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/error-badge-button-tests \
  Pharos/Core/PulseClock.swift \
  Pharos/Views/ErrorBadgeButton.swift \
  PharosTests/ErrorBadgeButtonTests.swift \
  PharosTests/main.swift
/tmp/error-badge-button-tests
