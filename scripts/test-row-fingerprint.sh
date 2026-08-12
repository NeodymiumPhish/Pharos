#!/bin/bash
# Standalone test runner for RowFingerprint. Pure Foundation, no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/row-fingerprint-tests \
  Pharos/Core/RowFingerprint.swift \
  PharosTests/RowFingerprintTests.swift \
  PharosTests/main.swift
/tmp/row-fingerprint-tests
