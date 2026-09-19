#!/bin/bash
# Standalone test runner for ModelAvailability's per-feature rule: the seven
# Apple Intelligence switches, and how they compose with the master switch and
# with what this Mac can actually run.
#
# The REAL Settings.swift is compiled in, so the defaults the test asserts are
# the shipped defaults. Only `AppStateManager` is stubbed, inside the test
# file — the real one reaches the core on init, and there is no initialised
# core behind a swiftc binary.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/model-availability-features-tests \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Core/Log.swift \
  Pharos/Intelligence/ModelAvailability.swift \
  PharosTests/ModelAvailabilityFeatureTests.swift \
  PharosTests/main.swift
/tmp/model-availability-features-tests
