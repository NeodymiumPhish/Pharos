#!/bin/bash
# Standalone test runner for the two pure completion decisions —
# CompletionTriggerPolicy (when the list opens) and KeywordCasing (what case an
# inserted keyword takes). No Xcode project involvement.
#
# Settings.swift comes along because it holds the two enums (CompletionTrigger,
# KeywordCase); ChartPalette is what Settings.swift needs to compile.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-completion-trigger-policy-tests \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Editor/CompletionTriggerPolicy.swift \
  Pharos/Editor/KeywordCasing.swift \
  PharosTests/CompletionTriggerPolicyTests.swift \
  PharosTests/main.swift
/tmp/pharos-completion-trigger-policy-tests
