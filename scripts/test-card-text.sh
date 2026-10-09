#!/bin/bash
# Live runner for card text: the real staticlib, no database. Proves the Swift
# <-> Rust JSON of a card split, serialize and notes extract (key casing,
# nulls), and that notes survive the text form and CardPersistence.
set -euo pipefail
cd "$(dirname "$0")/.."

# The app's Xcode pre-build phase makes this same call; incremental when current.
(cd pharos-core && cargo build --release)

BIN=/tmp/card-text-tests
swiftc -o "$BIN" \
  -I Pharos/CPharosCore \
  -L pharos-core/target/release -lpharos_core \
  -framework Security -framework SystemConfiguration -framework CoreFoundation \
  -lz -liconv -lm -lresolv \
  Pharos/Core/RustScalarError.swift \
  Pharos/Core/Log.swift \
  Pharos/Core/PharosCore.swift \
  Pharos/Core/PharosCore+Cards.swift \
  Pharos/Core/Cards/CardPersistence.swift \
  Pharos/Models/CardDocument.swift \
  Pharos/Core/VariableSubstitutor.swift \
  Pharos/Models/QueryVariable.swift \
  Pharos/Models/Connection.swift \
  PharosTests/CardTextTests.swift \
  PharosTests/main.swift

"$BIN"
