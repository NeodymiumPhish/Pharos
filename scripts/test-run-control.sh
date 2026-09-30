#!/bin/bash
# Standalone test runner for RunControl: the toolbar Run | Cancel transport
# control, in a real AppKit window ordered front off screen.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/run-control-tests \
  Pharos/Core/PulseClock.swift \
  Pharos/Core/RunControlState.swift \
  Pharos/Views/RunControl.swift \
  PharosTests/RunControlTests.swift \
  PharosTests/main.swift
/tmp/run-control-tests
