#!/bin/bash
# Standalone test runner for the "suggest a name" feature's model-free halves:
# NameSuggestionPolicy's prompt builder and its post-processing.
#
# Pure Foundation — no AppKit, no FoundationModels, no Rust library. The model
# is not, and cannot usefully be, exercised here; see the note at the top of
# PharosTests/NameSuggestionTests.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/name-suggestion-tests \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Intelligence/NameSuggestionPolicy.swift \
  PharosTests/NameSuggestionTests.swift \
  PharosTests/main.swift
/tmp/name-suggestion-tests
