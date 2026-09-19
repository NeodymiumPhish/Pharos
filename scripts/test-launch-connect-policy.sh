#!/bin/bash
# Standalone test runner for LaunchConnectPolicy: which connections Pharos
# opens for itself at launch, that one already opened by the session restore
# is left alone, and that the ones which will ask for Touch ID go last so they
# cannot hold up the ones that will not.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/launch-connect-policy-tests \
  Pharos/Core/LaunchConnectPolicy.swift \
  PharosTests/LaunchConnectPolicyTests.swift \
  PharosTests/main.swift
/tmp/launch-connect-policy-tests
