#!/bin/bash
# Standalone runner for CIDRRange. Foundation + Darwin only — the parser calls
# inet_pton/inet_ntop directly and imports no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/cidr-range-tests \
  Pharos/Core/CIDRRange.swift \
  PharosTests/CIDRRangeTests.swift \
  PharosTests/main.swift
/tmp/cidr-range-tests
