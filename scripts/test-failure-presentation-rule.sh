#!/bin/bash
# Standalone test runner for FailurePresentationRule: what a failed query does
# on screen under each alert style and sheet trigger, including that the
# defaults reproduce today's banner-then-sheet behaviour exactly.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/failure-presentation-rule-tests \
  Pharos/Core/FailurePresentationRule.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  PharosTests/FailurePresentationRuleTests.swift \
  PharosTests/main.swift
/tmp/failure-presentation-rule-tests
