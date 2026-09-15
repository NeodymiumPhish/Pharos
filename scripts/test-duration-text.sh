#!/bin/bash
# Standalone test runner for DurationText — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/duration-text-tests \
  Pharos/Utilities/DurationText.swift \
  PharosTests/DurationTextTests.swift \
  PharosTests/main.swift
/tmp/duration-text-tests
