#!/bin/bash
# Regenerate the two settings fixtures that the Swift decode test reads from
# the Rust struct that is the wire truth:
#   PharosTests/Fixtures/settings-default.json     — AppSettings::default()
#   PharosTests/Fixtures/settings-nondefault.json  — AppSettings::sample_non_default()
# Run it after any change to pharos-core/src/models/settings.rs, then commit
# both files. `cargo test` fails while they are stale.
set -euo pipefail
cd "$(dirname "$0")/../pharos-core"
PHAROS_PRINT_FIXTURE=1 cargo test --quiet --lib models::settings::fixture::print_fixtures -- --nocapture
