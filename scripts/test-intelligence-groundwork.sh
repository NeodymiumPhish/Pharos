#!/bin/bash
# Standalone test runner for the Phase 8 Apple Intelligence groundwork:
# GeneratedContentLabel, ModelFeedbackStore, ModelAvailability and
# IntelligenceGuard. Real AppKit, headless — no window is shown.
#
# `PharosCore` and `AppStateManager` are stubbed inside the test file, so the
# binary links without the Rust static library; see the note at the top of
# PharosTests/IntelligenceGroundworkTests.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/intelligence-groundwork-tests \
  Pharos/Core/Log.swift \
  Pharos/Intelligence/ModelAvailability.swift \
  Pharos/Intelligence/ModelFeedbackStore.swift \
  Pharos/Intelligence/GeneratedContentLabel.swift \
  Pharos/Intelligence/IntelligenceSession.swift \
  PharosTests/IntelligenceGroundworkTests.swift \
  PharosTests/main.swift
/tmp/intelligence-groundwork-tests
