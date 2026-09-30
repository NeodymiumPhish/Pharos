#!/bin/bash
# Standalone test runner for RunControlState: the toolbar Run | Cancel
# control's enabled states, pulse steps, tooltips and cancel action.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/run-control-state-tests \
  Pharos/Core/RunControlState.swift \
  PharosTests/RunControlStateTests.swift \
  PharosTests/main.swift
/tmp/run-control-state-tests
