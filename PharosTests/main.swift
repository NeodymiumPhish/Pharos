// Shared entry point for every standalone test binary in this repo.
//
// This project has no Xcode test target. Instead each `scripts/test-*.sh` invokes
// `swiftc` with the implementation files under test, exactly one test file from
// `PharosTests/` that declares `runTests()`, and this shim as the binary's `main`.
// One test file per binary is therefore the rule — two would collide on
// `runTests()` and on the assertion helpers each file defines for itself.
runTests()
