#!/bin/bash
# Standalone test runner for PlanSummaryPrompt — which nodes of a query plan
# are put to the on-device model, and what of each one.
#
# Pure Foundation: QueryPlan and the prompt builder, no AppKit and no
# FoundationModels. See the note at the top of
# PharosTests/PlanSummaryPromptTests.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/plan-summary-prompt-tests \
  Pharos/Models/QueryPlan.swift \
  Pharos/Intelligence/PlanSummaryPrompt.swift \
  PharosTests/PlanSummaryPromptTests.swift \
  PharosTests/main.swift
/tmp/plan-summary-prompt-tests
