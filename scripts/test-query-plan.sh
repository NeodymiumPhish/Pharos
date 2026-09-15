#!/bin/bash
# Standalone test runner for QueryPlan — no Xcode project involvement.
# Pure Foundation: the EXPLAIN (FORMAT JSON) decode and the plan arithmetic the
# plan view draws, and nothing else.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/query-plan-tests \
  Pharos/Models/QueryPlan.swift \
  PharosTests/QueryPlanTests.swift \
  PharosTests/main.swift
/tmp/query-plan-tests
