#!/bin/bash
# Standalone test runner for the session store's wire shape: `Session`,
# `SessionWindow` and `SessionTab` against the exact JSON `pharos-core`
# writes, plus the frame text a window's row carries.
#
# The FFI applies no key strategy, so a rename on either side silently empties
# the user's restored tabs instead of failing loudly. This suite is the thing
# that notices.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/session-store-shape-tests \
  Pharos/Models/Session.swift \
  PharosTests/SessionStoreShapeTests.swift \
  PharosTests/main.swift
/tmp/session-store-shape-tests
