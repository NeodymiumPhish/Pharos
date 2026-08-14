#!/bin/bash
# Live runner for TagStore: the real staticlib, a real SQLite file, no
# PostgreSQL. Two processes over one directory, so the second proves the write
# survived a restart.
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
  Pharos/Core/PharosCore+Tags.swift \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/TupleKey.swift \
  Pharos/Core/TagTupleMatcher.swift \
  Pharos/Core/TagStore.swift \
  Pharos/Models/Tag.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/TagStoreTests.swift \
  PharosTests/main.swift

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

"$BIN" write "$DIR"
echo
"$BIN" read "$DIR"
