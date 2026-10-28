#!/bin/bash
# Standalone test runner for VariableValueRules + ListPasteParser — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/variable-value-rules-tests \
  Pharos/Models/QueryVariable.swift \
  Pharos/Core/VariableSubstitutor.swift \
  Pharos/Core/VariableValueRules.swift \
  PharosTests/VariableValueRulesTests.swift \
  PharosTests/main.swift
/tmp/variable-value-rules-tests
