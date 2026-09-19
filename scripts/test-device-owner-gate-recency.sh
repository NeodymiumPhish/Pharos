#!/bin/bash
# Standalone test runner for DeviceOwnerGateRecency: how long one passed
# Touch ID gate counts for, including that the boundary is exclusive and that
# a pass timestamped in the FUTURE never counts.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/device-owner-gate-recency-tests \
  Pharos/Core/DeviceOwnerGateRecency.swift \
  PharosTests/DeviceOwnerGateRecencyTests.swift \
  PharosTests/main.swift
/tmp/device-owner-gate-recency-tests
