#!/bin/bash
# Live runner for saved Session results: the real staticlib and a real SQLite
# file in a temporary directory, no PostgreSQL. Proves the Swift <-> Rust JSON
# of a Session save and restore (key casing, nulls, raw row pass-through).
set -euo pipefail
cd "$(dirname "$0")/.."

# The app's Xcode pre-build phase makes this same call; incremental when current.
(cd pharos-core && cargo build --release)

BIN=/tmp/session-store-tests
swiftc -o "$BIN" \
  -I Pharos/CPharosCore \
  -L pharos-core/target/release -lpharos_core \
  -framework Security -framework SystemConfiguration -framework CoreFoundation \
  -lz -liconv -lm -lresolv \
  Pharos/Core/RustScalarError.swift \
  Pharos/Core/Log.swift \
  Pharos/Core/PharosCore.swift \
  Pharos/Core/PharosCore+SavedQueries.swift \
  Pharos/Models/Connection.swift \
  Pharos/Models/SavedQuery.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/QueryHistoryStatus.swift \
  Pharos/Models/QueryHistory.swift \
  PharosTests/SessionStoreTests.swift \
  PharosTests/main.swift

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
"$BIN" "$DIR"
