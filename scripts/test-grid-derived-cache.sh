#!/bin/bash
# Standalone test runner for GridDerivedCache. Pure Foundation, no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/grid-derived-cache-tests \
  Pharos/Core/GridDerivedCache.swift \
  PharosTests/GridDerivedCacheTests.swift \
  PharosTests/main.swift
/tmp/grid-derived-cache-tests
