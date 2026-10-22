#!/bin/bash
# Standalone test runner for VariableScope: global variables everywhere,
# linked ones only on their connections, the "linked elsewhere" error, and the
# QueryVariable JSON (connectionIds left out for a global variable).
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/variable-scope-tests \
  Pharos/Core/VariableScope.swift \
  Pharos/Models/QueryVariable.swift \
  Pharos/Models/Connection.swift \
  PharosTests/VariableScopeTests.swift \
  PharosTests/main.swift
/tmp/variable-scope-tests
