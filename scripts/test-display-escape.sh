#!/bin/bash
# Standalone test runner for DisplayEscape. Pure Foundation, no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/display-escape-tests \
  Pharos/Core/DisplayEscape.swift \
  PharosTests/DisplayEscapeTests.swift \
  PharosTests/main.swift
/tmp/display-escape-tests
