#!/bin/bash
# Standalone test runner for VariableSubstitutor — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/variable-substitutor-tests \
  Pharos/Models/QueryVariable.swift \
  Pharos/Core/VariableSubstitutor.swift \
  PharosTests/VariableSubstitutorTests.swift \
  PharosTests/main.swift
/tmp/variable-substitutor-tests
