#!/bin/bash
# Standalone test runner for the row tag models and the result row identity —
# no Xcode project involvement.
#
# Pharos/Core/PharosCore.swift is deliberately NOT compiled in: it calls the
# generated C FFI (pharos_*) through a bridging header that only the app target
# supplies. The suite therefore uses a plain JSONDecoder()/JSONEncoder(), which
# is exactly what `JSONDecoder.pharos` / `JSONEncoder.pharos` are — see
# PharosCore.swift, where both are `{ JSONDecoder() }` with NO key strategy.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/row-tag-model-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/QueryHistory.swift \
  Pharos/Models/RowTag.swift \
  PharosTests/RowTagModelTests.swift \
  PharosTests/main.swift
/tmp/row-tag-model-tests
