#!/bin/bash
# Turnkey seed / undo for the Task 10 visual pass (Tag Row Phase 2) — creates one
# real row tag against the REAL Pharos store, so reopening
# `SELECT * FROM tagtest.users` in the app shows a tag dot on a real row.
#
# WHERE THE TAG LANDS
#   Row: tagtest.users, id=1, email='a@b.co' (see scripts/tagtest-schema.sql —
#   that's the first row the fixture inserts). Two candidate keys are written,
#   pk (id) and unique (email), matching what the catalogue query would find.
#
# THE OID PROBLEM
#   PharosTests/RowTagFFILiveTests.swift hardcodes tableKey "oid:16543" — the
#   OID tagtest.users happened to get on the machine that harness was written
#   on. On THIS machine tagtest.users is oid:609999, and a tag only matches a
#   result when its tableKey agrees with the result's own (oid:<relation_oid>,
#   see pharos-core/src/models/row_tag.rs and commands/row_tag.rs). Editing the
#   committed harness would make it machine-specific, which defeats its
#   purpose as the phase-1 regression suite — so this script never touches it.
#   Instead it builds from a PATCHED COPY in /tmp, substituting the real OID at
#   build time via sed. The file under PharosTests/ is read, never written.
#
# THE SECOND, MORE IMPORTANT PATCH
#   RowTagFFILiveTests.swift's read phase undoes the write by deleting
#   `labels.first` — correct ONLY when the store holds exactly the one label
#   this script just created. The REAL store may already carry the user's own
#   labels. Blindly taking `labels.first` there risks cascading a delete onto
#   someone else's real label and tag — this was verified against a mktemp
#   store seeded with an extra label first: unpatched, `read` targets whichever
#   label the store returns first (not necessarily ours); patched, it always
#   targets the label named "Check", which is the one this script created.
#   This script's patched copy also carries that fix, so `read` only ever
#   removes the label this script made — never an unrelated one.
#
# WHAT THIS SCRIPT DOES NOT FIX
#   RowTagFFILiveTests.swift's assertions also assume a FRESH, single-label
#   store (e.g. "a fresh store holds no labels", "the label is gone" meaning
#   zero labels total). Against a real store that already has data, those two
#   specific lines will print FAIL even though nothing went wrong — they are
#   counting ALL labels, not just this script's. What proves the write/undo
#   actually worked is the OTHER PASS lines: "the stored tag holds both
#   candidate keys" (write) and "the cascade took the tag" (read, undo) — that
#   second one checks tags for THIS connection id specifically, so a PASS
#   there means the cascade removed OUR tag, whatever else remains.
#
# SAFETY
#   - Refuses to run while Pharos.app is open (it holds the same SQLite file
#     this script writes to; a concurrent writer can corrupt it).
#   - Touches only ~/Library/Application Support/Pharos/pharos.db — the REAL
#     store — and prints exactly what it is about to do before doing it.
#   - Never edits anything under PharosTests/ or any other committed file.
#
# Usage:
#   scripts/seed-tag-for-visual-check.sh write   # create the "Check" label + one tag
#   scripts/seed-tag-for-visual-check.sh read    # delete "Check" (cascades the tag) — the undo
set -euo pipefail
cd "$(dirname "$0")/.."

OID=609999
REAL_DIR="$HOME/Library/Application Support/Pharos"
PATCHED_SRC=/tmp/RowTagFFILiveTests.visual-check.swift
BIN=/tmp/tag-seed-visual-check

if [[ $# -ne 1 ]] || { [[ "$1" != "write" ]] && [[ "$1" != "read" ]]; }; then
    echo "usage: $0 <write|read>" >&2
    exit 2
fi
PHASE="$1"

if pgrep -x Pharos >/dev/null 2>&1; then
    echo "REFUSING: Pharos is running. Quit it first." >&2
    echo "It holds the same SQLite file this script writes to; a concurrent" >&2
    echo "writer can corrupt it." >&2
    exit 1
fi

echo "About to run the '$PHASE' phase against the REAL Pharos store:"
echo "  store:  $REAL_DIR/pharos.db"
echo "  table:  tagtest.users, oid:$OID"
echo "  row:    id=1, email='a@b.co'"
if [[ "$PHASE" == "write" ]]; then
    echo "  action: create one tag label (\"Check\") and one tag on that row"
else
    echo "  action: delete the \"Check\" label — cascades to delete its tag (the undo)"
    echo "          (any OTHER label/tag already in the store is left untouched)"
fi
echo
read -r -p "Proceed? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 1
fi

echo
echo "Building the seed binary (real OID + label-targeting fix patched in;"
echo "PharosTests/RowTagFFILiveTests.swift itself is untouched)..."
sed -e "s/oid:16543/oid:$OID/" \
    -e 's/label = labels\.first$/label = labels.first(where: { $0.name == "Check" })/' \
    PharosTests/RowTagFFILiveTests.swift > "$PATCHED_SRC"

(cd pharos-core && cargo build --release)

swiftc -o "$BIN" \
  -I Pharos/CPharosCore \
  -L pharos-core/target/release -lpharos_core \
  -framework Security -framework SystemConfiguration -framework CoreFoundation \
  -lz -liconv -lm -lresolv \
  Pharos/Core/RustScalarError.swift \
  Pharos/Core/PharosCore.swift \
  Pharos/Core/PharosCore+RowTags.swift \
  Pharos/Models/RowTag.swift \
  "$PATCHED_SRC" \
  PharosTests/main.swift

echo
"$BIN" "$PHASE" "$REAL_DIR"
