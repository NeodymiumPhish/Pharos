#!/bin/bash
# Standalone test runner for TabConnectionDot / TabConnectionState — no Xcode
# project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-tab-connection-dot-tests \
  Pharos/Views/TabConnectionDot.swift \
  Pharos/Core/PulseClock.swift \
  Pharos/Models/Connection.swift \
  PharosTests/TabConnectionDotTests.swift \
  PharosTests/main.swift
/tmp/pharos-tab-connection-dot-tests
