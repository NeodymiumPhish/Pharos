#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/value-coercion-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ValueCoercion.swift \
  PharosTests/ValueCoercionTests.swift \
  PharosTests/main.swift
/tmp/value-coercion-tests
