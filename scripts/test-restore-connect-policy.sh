#!/bin/bash
# Standalone test runner for RestoreConnectPolicy: relaunch restore opens
# the DuckDB files the restored tabs use, nothing else.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t restore-connect-policy-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Models/Connection.swift \
  Pharos/Core/RestoreConnectPolicy.swift \
  PharosTests/RestoreConnectPolicyTests.swift \
  PharosTests/main.swift
"$BIN"
