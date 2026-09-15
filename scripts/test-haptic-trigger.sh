#!/bin/bash
# Standalone test runner for Haptics — no Xcode project involvement.
# Only Haptics.swift is compiled: it is AppKit-only (NSHapticFeedbackManager)
# and generic over Equatable specifically so it never needs
# ContentViewController.swift (which nests ContentExpandState but pulls in
# the FFI bridge and cannot compile standalone).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=$(mktemp -u /tmp/haptic-trigger-tests.XXXXXX)
swiftc -o "$BIN" \
  Pharos/Core/Haptics.swift \
  PharosTests/HapticTriggerTests.swift \
  PharosTests/main.swift
"$BIN"
