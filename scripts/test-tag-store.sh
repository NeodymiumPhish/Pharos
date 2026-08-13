#!/bin/bash
# Integration runner for TagStore — Task 6 of the tag row phase 2 plan.
#
# Like test-row-tag-ffi.sh, this links the real Rust staticlib and writes a real
# SQLite file. It needs no PostgreSQL: row tags are local. Unlike that suite, ONE
# process is enough here — this is not testing persistence across a restart, it is
# testing that TagStore builds the right in-memory index from what the FFI hands
# back.
#
# The store lives in a mktemp -d that is removed on exit, so this never touches
# the user's own Application Support database.
set -euo pipefail
cd "$(dirname "$0")/.."

# The app's Xcode pre-build phase makes this same call; incremental when current.
(cd pharos-core && cargo build --release)

BIN=/tmp/tag-store-tests
swiftc -o "$BIN" \
  -I Pharos/CPharosCore \
  -L pharos-core/target/release -lpharos_core \
  -framework Security -framework SystemConfiguration -framework CoreFoundation \
  -lz -liconv -lm -lresolv \
  Pharos/Core/RustScalarError.swift \
  Pharos/Core/PharosCore.swift \
  Pharos/Core/PharosCore+RowTags.swift \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Core/TagMatcher.swift \
  Pharos/Core/TagLabelPalette.swift \
  Pharos/Core/TagStore.swift \
  Pharos/Models/RowTag.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/TagStoreTests.swift \
  PharosTests/main.swift

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

"$BIN" "$DIR"
