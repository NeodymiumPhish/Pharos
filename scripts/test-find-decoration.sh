#!/bin/bash
# Standalone test runner for FindMatchDecoration — the find-match border rule.
# Pure AppKit, headless, no FFI.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/find-decoration-tests \
  Pharos/ViewControllers/ResultsGrid/FindMatchDecoration.swift \
  PharosTests/FindMatchDecorationTests.swift \
  PharosTests/main.swift
/tmp/find-decoration-tests
