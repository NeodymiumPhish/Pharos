#!/bin/bash
# Standalone test runner for AppInfo: the version and build strings Settings ▸
# About reports, and the three web addresses Pharos opens. No bundle, no
# AppKit, no FFI — every string comes from a dictionary the test supplies.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/app-info-tests \
  Pharos/Core/AppInfo.swift \
  PharosTests/AppInfoTests.swift \
  PharosTests/main.swift
/tmp/app-info-tests
