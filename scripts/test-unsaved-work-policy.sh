#!/bin/bash
# Standalone test runner for `UnsavedWorkPolicy` — which editor tabs count as
# unsaved work before a tab, a window or the app closes, and the words the
# warning uses. Every combination of dirty / bound / empty against the
# **Restore open tabs** setting, because the point of the rule is the case
# where a warning would be a lie. Foundation only; no AppKit, no FFI.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t unsaved-work-policy-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Core/UnsavedWorkPolicy.swift \
  PharosTests/UnsavedWorkPolicyTests.swift \
  PharosTests/main.swift
"$BIN"
