#!/bin/bash
# Standalone test runner for GeneratedTextPolicy: what Pharos does to prose
# and SQL a model wrote before showing or inserting it. Foundation only.
set -euo pipefail
cd "$(dirname "$0")/.."
bin=/tmp/pharos-generated-text-policy-tests
swiftc -o "$bin" \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Intelligence/GeneratedTextPolicy.swift \
  PharosTests/GeneratedTextPolicyTests.swift \
  PharosTests/main.swift
"$bin"
