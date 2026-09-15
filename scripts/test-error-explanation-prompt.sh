#!/bin/bash
# Standalone test runner for the "Explain this error" prompt builder.
#
# Foundation only: ErrorExplanationPrompt.swift imports nothing else, so this
# binary needs neither FoundationModels nor the Rust core. The @Generable type
# and the session live in ErrorExplanation.swift and are NOT compiled here.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/error-explanation-prompt-tests \
  Pharos/Intelligence/ErrorExplanationPrompt.swift \
  PharosTests/ErrorExplanationPromptTests.swift \
  PharosTests/main.swift
/tmp/error-explanation-prompt-tests
