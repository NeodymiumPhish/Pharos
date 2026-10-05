#!/bin/bash
# Standalone test runner for ModelErrorKind, the one reading of a model
# failure for macOS 26 (GenerationError) and macOS 27 (LanguageModelError).
set -euo pipefail
cd "$(dirname "$0")/.."
bin=/tmp/pharos-model-error-kind-tests
swiftc -o "$bin" \
  Pharos/Intelligence/ModelErrorKind.swift \
  PharosTests/ModelErrorKindTests.swift \
  PharosTests/main.swift
"$bin"
