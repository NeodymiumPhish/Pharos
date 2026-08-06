#!/bin/bash
# Standalone test runner for the Toast click handler. Real AppKit, headless window.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/toast-click-tests \
  Pharos/Views/Toast.swift \
  PharosTests/ToastClickTests.swift \
  PharosTests/main.swift
/tmp/toast-click-tests
