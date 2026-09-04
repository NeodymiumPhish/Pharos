#!/bin/bash
# Standalone test runner for FoldState — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/fold-state-tests \
  Pharos/Editor/FoldState.swift \
  PharosTests/FoldStateTests.swift \
  PharosTests/main.swift
/tmp/fold-state-tests
