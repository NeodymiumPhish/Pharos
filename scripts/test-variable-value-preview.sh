#!/bin/bash
# Standalone test runner for VariableValuePreview — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/variable-value-preview-tests \
  Pharos/Core/VariableValuePreview.swift \
  PharosTests/VariableValuePreviewTests.swift \
  PharosTests/main.swift
/tmp/variable-value-preview-tests
