#!/bin/bash
# Standalone test runner for DestructiveConfirmations: which kinds of
# database-changing statement still raise the confirmation, that the default
# confirms every one, and that an unrecognised keyword fails SAFE (it asks).
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/destructive-confirmations-tests \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  PharosTests/DestructiveConfirmationsTests.swift \
  PharosTests/main.swift
/tmp/destructive-confirmations-tests
