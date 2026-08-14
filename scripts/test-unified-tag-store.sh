#!/bin/bash
# Live runner for the unified TagStore: the real staticlib, a real SQLite file,
# no PostgreSQL. Two processes over one directory, so the second proves the
# write survived a restart.
#
# The four row-tag files are compiled in ONLY because TagStore still carries its
# per-connection half at this point — `createLabel` reads TagLabelPalette and
# `reload` calls TagMatcher.index. Task 12 deletes that half and trims this
# list back to the tag files alone.
set -euo pipefail
cd "$(dirname "$0")/.."

# The app's Xcode pre-build phase makes this same call; incremental when current.
(cd pharos-core && cargo build --release)

BIN=/tmp/unified-tag-store-tests
swiftc -o "$BIN" \
  -I Pharos/CPharosCore \
  -L pharos-core/target/release -lpharos_core \
  -framework Security -framework SystemConfiguration -framework CoreFoundation \
  -lz -liconv -lm -lresolv \
  Pharos/Core/RustScalarError.swift \
  Pharos/Core/PharosCore.swift \
  Pharos/Core/PharosCore+Tags.swift \
  Pharos/Core/PharosCore+RowTags.swift \
  Pharos/Models/RowTag.swift \
  Pharos/Core/TagMatcher.swift \
  Pharos/Core/TagLabelPalette.swift \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/TupleKey.swift \
  Pharos/Core/TagTupleMatcher.swift \
  Pharos/Core/TagStore.swift \
  Pharos/Models/Tag.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/UnifiedTagStoreTests.swift \
  PharosTests/main.swift

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

"$BIN" write "$DIR"
echo
"$BIN" read "$DIR"
