#!/bin/bash
# Integration runner for the row tag FFI — Task 11 Step 5 of the phase 1 plan.
#
# Unlike the other suites here, this one links the real Rust staticlib and writes
# a real SQLite file. It needs no PostgreSQL: the tag store is local.
#
# The store lives in a mktemp -d that is removed on exit, so this never touches
# the user's own Application Support database. The binary runs TWICE against that
# one directory — a second process is what proves the write survived, which is the
# "quit the app and run the load again" of Step 5.
set -euo pipefail
cd "$(dirname "$0")/.."

# The app's Xcode pre-build phase makes this same call; incremental when current.
(cd pharos-core && cargo build --release)

BIN=/tmp/row-tag-ffi-tests
swiftc -o "$BIN" \
  -I Pharos/CPharosCore \
  -L pharos-core/target/release -lpharos_core \
  -framework Security -framework SystemConfiguration -framework CoreFoundation \
  -lz -liconv -lm -lresolv \
  Pharos/Core/RustScalarError.swift \
  Pharos/Core/PharosCore.swift \
  Pharos/Core/PharosCore+RowTags.swift \
  Pharos/Models/RowTag.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Core/TagComposer.swift \
  Pharos/Core/TagMatcher.swift \
  Pharos/Core/TagLabelPalette.swift \
  Pharos/Core/TagStore.swift \
  PharosTests/RowTagFFILiveTests.swift \
  PharosTests/main.swift

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

"$BIN" write "$DIR"
echo
"$BIN" read "$DIR"
