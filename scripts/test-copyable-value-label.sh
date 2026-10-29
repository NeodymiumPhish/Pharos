#!/bin/bash
# Standalone test runner for the Inspector's row-detail value label. Real
# AppKit: the events go through NSApplication.sendEvent to an on-screen window
# placed far off every display.
#
# The binary name is unique to this suite: every test-*.sh writes a fixed path,
# and two suites sharing one would clobber each other when run concurrently.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/copyable-value-label-tests \
  Pharos/Views/CopyableValueLabel.swift \
  Pharos/Core/DisplayEscape.swift \
  PharosTests/CopyableValueLabelTests.swift \
  PharosTests/main.swift
/tmp/copyable-value-label-tests
