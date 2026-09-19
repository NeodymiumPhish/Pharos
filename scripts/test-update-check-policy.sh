#!/bin/bash
# Standalone test runner for the pure parts of the update check: version tag
# parsing (a pre-release suffix is dropped, not rejected), which release the
# pre-release channel picks, and what each frequency asks of the timer and the
# rate limit. No AppKit, no network.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/update-check-policy-tests \
  Pharos/Core/UpdateCheckPolicy.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  PharosTests/UpdateCheckPolicyTests.swift \
  PharosTests/main.swift
/tmp/update-check-policy-tests
