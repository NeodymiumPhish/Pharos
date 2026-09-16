#!/bin/bash
# Live runner for QueryVariableStore: the real staticlib, a real SQLite file,
# no PostgreSQL. Two processes over one directory, so the second proves the
# write survived a restart.
set -euo pipefail
cd "$(dirname "$0")/.."

# The app's Xcode pre-build phase makes this same call; incremental when current.
(cd pharos-core && cargo build --release)

BIN=/tmp/query-variable-store-tests
swiftc -o "$BIN" \
  -I Pharos/CPharosCore \
  -L pharos-core/target/release -lpharos_core \
  -framework Security -framework SystemConfiguration -framework CoreFoundation \
  -lz -liconv -lm -lresolv \
  Pharos/Core/RustScalarError.swift \
  Pharos/Core/Log.swift \
  Pharos/Core/PharosCore.swift \
  Pharos/Core/PharosCore+QueryVariables.swift \
  Pharos/Core/QueryVariableStore.swift \
  Pharos/Models/QueryVariable.swift \
  PharosTests/QueryVariableStoreTests.swift \
  PharosTests/main.swift

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

"$BIN" write "$DIR"
echo
"$BIN" read "$DIR"
