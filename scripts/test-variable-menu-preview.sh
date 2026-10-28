#!/bin/bash
# Standalone test runner for VariableMenuPreview — the Variables pull-down's
# "Renders as" row. Foundation only.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/variable-menu-preview-tests \
  Pharos/Models/QueryVariable.swift \
  Pharos/Core/VariableSubstitutor.swift \
  Pharos/Core/VariableValueRules.swift \
  Pharos/Core/VariableMenuPreview.swift \
  PharosTests/VariableMenuPreviewTests.swift \
  PharosTests/main.swift
/tmp/variable-menu-preview-tests
