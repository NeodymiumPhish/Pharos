#!/bin/bash
# Standalone test runner for RustScalarError — the FFI's failure-object check.
# Pure Foundation, no CPharosCore, so it compiles without the Rust library.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/rust-scalar-error-tests \
  Pharos/Core/RustScalarError.swift \
  PharosTests/RustScalarErrorTests.swift \
  PharosTests/main.swift
/tmp/rust-scalar-error-tests
