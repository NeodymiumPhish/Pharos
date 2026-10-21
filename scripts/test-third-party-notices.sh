#!/bin/bash
# Fail when THIRD_PARTY_NOTICES.md or Pharos/Files/Acknowledgements.txt no
# longer matches what is linked (a crate, DuckDB or an extension changed).
# Fix: scripts/gen-third-party-notices.sh, then commit both files.
# Needs the arm64 DuckDB build tree (scripts/build-duckdb.sh arm64).
set -euo pipefail
exec "$(dirname "$0")/gen-third-party-notices.sh" --check
