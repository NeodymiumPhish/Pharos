#!/bin/bash
# Standalone test runner for QueryErrorBanner — no window, no ContentViewController.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/query-error-banner-tests \
  Pharos/Core/SQLErrorLocation.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Models/QueryFailure.swift \
  Pharos/Views/QueryErrorBanner.swift \
  PharosTests/QueryErrorBannerTests.swift \
  PharosTests/main.swift
/tmp/query-error-banner-tests
