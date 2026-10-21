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
  -lz -liconv -lm -lresolv -lc++ -lcompression \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Core/RustScalarError.swift \
  Pharos/Core/Log.swift \
  Pharos/Core/PharosCore.swift \
  Pharos/Core/PharosCore+Tags.swift \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Utilities/SQLTypeName.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/RuleKey.swift \
  Pharos/Core/TagRuleMatcher.swift \
  Pharos/Core/TagRuleRemoving.swift \
  Pharos/Core/TagManagerCommitting.swift \
  Pharos/Core/TagCommitWriting.swift \
  Pharos/Core/TagManagerModel.swift \
  Pharos/Core/TagCapture.swift \
  Pharos/Core/CountedNounText.swift \
  Pharos/Core/TagDraft.swift \
  Pharos/Core/TagFamilyLabel.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/TagStore.swift \
  Pharos/Core/TagConditionKind.swift \
  Pharos/Core/TagGlob.swift \
  Pharos/Core/TagPredicate.swift \
  Pharos/Models/Connection.swift \
  Pharos/Models/Tag.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/TagStoreTests.swift \
  PharosTests/main.swift

# pharos_init reads the Keychain. A scratch service keeps the user's real item
# out of the test; with it, a rebuilt binary raised an access prompt and hung.
export PHAROS_KEYCHAIN_SERVICE=com.pharos.test.harness

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

"$BIN" write "$DIR"
echo
"$BIN" read "$DIR"
