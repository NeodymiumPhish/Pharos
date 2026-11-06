#!/bin/bash
# Standalone test runner for ResultMemoryBudget. Pure Foundation, no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/result-memory-budget-tests \
  Pharos/Core/ResultMemoryBudget.swift \
  PharosTests/ResultMemoryBudgetTests.swift \
  PharosTests/main.swift
/tmp/result-memory-budget-tests
