#!/bin/bash
# Standalone test runner for the "suggest a chart" feature's model-free half:
# ChartSuggestionPolicy's prompt builder and its answer validation.
#
# Pure Foundation — no AppKit, no FoundationModels, no Rust library. The model
# is not exercised here; ChartSuggestion.swift (the session) is excluded.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/chart-suggestion-policy-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/ChartConfig.swift \
  Pharos/Models/Charts/ColumnClassifier.swift \
  Pharos/Models/Charts/ValueCoercion.swift \
  Pharos/Models/Charts/ColumnProfile.swift \
  Pharos/Models/Charts/ChartRoleEligibility.swift \
  Pharos/Models/Charts/ChartAxisTitles.swift \
  Pharos/Models/Charts/ChartRecommender.swift \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Intelligence/ChartSuggestionPolicy.swift \
  PharosTests/ChartSuggestionPolicyTests.swift \
  PharosTests/main.swift
/tmp/chart-suggestion-policy-tests
