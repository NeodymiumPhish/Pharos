#!/bin/bash
# Build pharos-core as a static library for macOS
# Output: target/release/libpharos_core.a + include/pharos_core.h

set -e

cd "$(dirname "$0")"

echo "Building pharos-core (release)..."
cargo build --release

echo ""
echo "Static library: $(ls -lh target/release/libpharos_core.a | awk '{print $5}')"
echo "  → target/release/libpharos_core.a"
echo "C header:"
echo "  → include/pharos_core.h"
echo ""
echo "Done."
