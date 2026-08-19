#!/bin/bash
# Standalone test runner for InspectorOwnership. Pure Foundation, no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/inspector-ownership-tests \
  Pharos/Core/InspectorOwnership.swift \
  PharosTests/InspectorOwnershipTests.swift \
  PharosTests/main.swift
/tmp/inspector-ownership-tests
