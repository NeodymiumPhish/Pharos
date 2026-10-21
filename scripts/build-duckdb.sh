#!/bin/bash
# Build DuckDB with Pharos's built-in extensions as static libraries.
#
#   scripts/build-duckdb.sh [arm64|x86_64]      (default: this Mac's architecture)
#
# Output: pharos-core/target/duckdb/<rust-target>/lib/*.a   (linked by pharos-core/build.rs)
#
# DuckDB, its extensions and vcpkg are pinned below; the extensions are listed
# in pharos-core/duckdb/extension_config.cmake. The work is skipped when the
# output's stamp matches every input, so the Xcode pre-build and CI can call
# this every time. The first build of an architecture takes several minutes.
set -euo pipefail

# Everything is inside main, which bash reads whole before it runs: an edit to
# this file during a build cannot change what the running build does.
main() {

    ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    CORE="$ROOT/pharos-core"

    DUCKDB_TAG="v1.5.6"
    DUCKDB_COMMIT="069cc9f9b5"            # what v1.5.6 points at (checked below)
    VCPKG_TAG="2026.10.16"               # OpenSSL 3.6.5, curl 8.23.0, libpq 18.4 (DuckDB v1.5.6 names 2025.12.12)
    DEPLOYMENT_TARGET="26.0"             # the app's minimum macOS (project.yml)

    ARCH="${1:-$(uname -m)}"
    case "$ARCH" in
        arm64|aarch64) ARCH=arm64; RUST_TARGET=aarch64-apple-darwin; TRIPLET=arm64-osx-pharos; PLATFORM=osx_arm64 ;;
        x86_64)        RUST_TARGET=x86_64-apple-darwin; TRIPLET=x64-osx-pharos; PLATFORM=osx_amd64 ;;
        *) echo "build-duckdb: unknown architecture '$ARCH' (arm64 or x86_64)" >&2; exit 2 ;;
    esac

    # The sources and build folders (several GB). CI moves them out of target/,
    # which its Rust cache saves.
    WORK="${PHAROS_DUCKDB_WORK:-$CORE/target/duckdb-build}"
    SRC="$WORK/src"
    VCPKG="$WORK/vcpkg"
    BUILD="$WORK/build-$ARCH"
    OUT="$CORE/target/duckdb/$RUST_TARGET"
    CONFIG="$CORE/duckdb/extension_config.cmake"
    TRIPLETS="$CORE/duckdb/triplets"

    # target/duckdb/native is this Mac's own build: .cargo/config.toml points
    # libduckdb-sys there, so a plain `cargo build` works on arm64 and Intel.
    if [ "$ARCH" = "$(uname -m)" ]; then
        mkdir -p "$CORE/target/duckdb"
        ln -sfn "$RUST_TARGET" "$CORE/target/duckdb/native"
    fi

    # The stamp: everything that changes what is built.
    STAMP_INPUT="$(cat "$0" "$CONFIG" "$TRIPLETS/$TRIPLET.cmake"; echo "$DUCKDB_TAG $VCPKG_TAG $DEPLOYMENT_TARGET $ARCH")"
    STAMP="$(printf '%s' "$STAMP_INPUT" | shasum -a 256 | cut -d' ' -f1)"
    if [ -f "$OUT/stamp" ] && [ "$(cat "$OUT/stamp")" = "$STAMP" ]; then
        echo "build-duckdb: $RUST_TARGET is up to date"
        exit 0
    fi

    # Xcode's pre-build exports these for the app; DuckDB and vcpkg get the
    # deployment target explicitly instead, and must not pick up Xcode's SDK
    # variables for the wrong architecture.
    unset MACOSX_DEPLOYMENT_TARGET ARCHS NATIVE_ARCH
    # cmake and ninja come from Homebrew; Xcode's build phases do not have it on PATH.
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

    mkdir -p "$WORK"
    if [ ! -d "$SRC/.git" ]; then
        git clone --depth 1 --branch "$DUCKDB_TAG" https://github.com/duckdb/duckdb.git "$SRC"
    fi
    HEAD="$(git -C "$SRC" rev-parse --short=10 HEAD)"
    if [ "$HEAD" != "$DUCKDB_COMMIT" ]; then
        echo "build-duckdb: $SRC is at $HEAD, expected $DUCKDB_TAG ($DUCKDB_COMMIT)" >&2
        exit 1
    fi

    if [ ! -x "$VCPKG/vcpkg" ]; then
        if [ ! -d "$VCPKG/.git" ]; then
            git clone --depth 1 --branch "$VCPKG_TAG" https://github.com/microsoft/vcpkg.git "$VCPKG"
        fi
        "$VCPKG/bootstrap-vcpkg.sh" -disableMetrics
    fi
    export VCPKG_DISABLE_METRICS=1
    # Built ports are reused across builds and architectures (and cached by CI).
    export VCPKG_DEFAULT_BINARY_CACHE="$WORK/vcpkg-cache"
    mkdir -p "$VCPKG_DEFAULT_BINARY_CACHE"

    COMMON=(
        -G Ninja
        -DCMAKE_BUILD_TYPE=Release
        -DDUCKDB_EXTENSION_CONFIGS="$CONFIG"
        -DOVERRIDE_GIT_DESCRIBE="$DUCKDB_TAG"
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
        # Not OSX_BUILD_ARCH: DuckDB's CMakeLists forces the deployment target to
        # 11.0 when that is set.
        -DCMAKE_OSX_ARCHITECTURES="$ARCH"
        # Else DuckDB runs a probe binary of the target architecture, which an
        # arm64 Mac without Rosetta cannot run for x86_64.
        -DDUCKDB_EXPLICIT_PLATFORM="$PLATFORM"
        -DBUILD_SHELL=0
        -DBUILD_UNITTESTS=0
        -DENABLE_EXTENSION_AUTOLOADING=1
        -DENABLE_EXTENSION_AUTOINSTALL=0
        -DENABLE_SANITIZER=0
        -DENABLE_UBSAN=0
    )

    # 1. The merged vcpkg manifest of the extensions (DuckDB's own step). Its
    #    merge script writes build/extension_configuration/vcpkg.json inside the
    #    SOURCE tree, whatever the build folder is.
    mkdir -p "$SRC/build/extension_configuration"
    cmake -S "$SRC" -B "$BUILD/extension_configuration" "${COMMON[@]}" \
        -DEXTENSION_CONFIG_BUILD=TRUE > "$BUILD.config.log" 2>&1 \
        && cmake --build "$BUILD/extension_configuration" >> "$BUILD.config.log" 2>&1 \
        || { tail -40 "$BUILD.config.log"; exit 1; }
    MANIFEST_DIR="$SRC/build/extension_configuration"
    [ -f "$MANIFEST_DIR/vcpkg.json" ] || { echo "build-duckdb: no merged vcpkg.json in $MANIFEST_DIR" >&2; exit 1; }
    # sqlite_scanner's manifest (at the pinned commit) lists openssl and curl, but
    # none of its sources include or link either (checked with grep, 2026-10-20).
    # Building them would cost minutes and put OpenSSL in the app for nothing.
    python3 -I - "$MANIFEST_DIR/vcpkg.json" "$VCPKG/ports" "$(git -C "$VCPKG" rev-parse HEAD)" <<'PY'
import json, os, re, sys
path, ports, vcpkg_head = sys.argv[1], sys.argv[2], sys.argv[3]
manifest = json.load(open(path))
unused = set()  # SPIKE: httpfs and postgres_scanner need what the manifests list
deps, seen = [], set()
for d in manifest.get("dependencies", []):
    name = d if isinstance(d, str) else d.get("name")
    if name in unused or name in seen:
        continue
    seen.add(name)
    deps.append(d)
manifest["dependencies"] = deps
# The ports come from the checked-out vcpkg (VCPKG_TAG), whatever baseline
# DuckDB's manifest names: a shallow clone has no other commit, and this is
# what makes a VCPKG_TAG bump the one edit that updates OpenSSL, curl,
# libpq, expat and minizip-ng (SECURITY.md).
manifest["builtin-baseline"] = vcpkg_head
def numbers(v):
    return tuple(int(x) for x in re.findall(r"\d+", v))
def version(port_dir):
    port = json.load(open(os.path.join(port_dir, "vcpkg.json")))
    return port.get("version") or port.get("version-semver") or port.get("version-string")
# A version override makes vcpkg read old port versions from git history,
# which the shallow clone lacks. DuckDB's merge script always writes one for
# openssl (3.6.0 for v1.5.6). Drop each override whose series (major.minor)
# the checked-out port has at the same or a newer patch: that is the security
# update. Stop on any other, so a new series is a decision, not a side effect.
for o in manifest.pop("overrides", []):
    have = version(os.path.join(ports, o["name"]))
    if numbers(have)[:2] != numbers(o["version"])[:2] or numbers(have) < numbers(o["version"]):
        sys.exit(f"build-duckdb: {o['name']} override {o['version']} but vcpkg {have}; use a vcpkg with that series")
    print(f"build-duckdb: {o['name']} {have} (DuckDB's override {o['version']})")
# The extensions bring overlay ports, which vcpkg uses before its own ports:
# postgres_scanner's libpq (18.3) and excel's expat (2.6.4), minizip-ng
# (4.0.7) and zlib. On macOS they differ from vcpkg's ports only in version
# and fixes for other platforms. Drop them, so the libraries come from
# VCPKG_TAG; stop if that would go back in version or change the major.
config = manifest.get("vcpkg-configuration", {})
for overlay in config.pop("overlay-ports", []):
    for name in sorted(os.listdir(overlay)):
        theirs, have = version(os.path.join(overlay, name)), version(os.path.join(ports, name))
        if numbers(have)[:1] != numbers(theirs)[:1] or numbers(have) < numbers(theirs):
            sys.exit(f"build-duckdb: {name} {theirs} in {overlay} but vcpkg {have}; use a vcpkg with that major")
        print(f"build-duckdb: {name} {have} (the extension's overlay port {theirs})")
json.dump(manifest, open(path, "w"), indent=2)
print("build-duckdb: vcpkg dependencies:", [d if isinstance(d, str) else d["name"] for d in manifest["dependencies"]])
PY

    # 2. DuckDB, the extensions, and their vcpkg libraries.
    cmake -S "$SRC" -B "$BUILD/release" "${COMMON[@]}" \
        -DCMAKE_TOOLCHAIN_FILE="$VCPKG/scripts/buildsystems/vcpkg.cmake" \
        -DVCPKG_BUILD=1 \
        -DVCPKG_TARGET_TRIPLET="$TRIPLET" \
        -DVCPKG_HOST_TRIPLET="$( [ "$(uname -m)" = arm64 ] && echo arm64-osx-pharos || echo x64-osx-pharos )" \
        -DVCPKG_OVERLAY_TRIPLETS="$TRIPLETS" \
        -DVCPKG_MANIFEST_DIR="$MANIFEST_DIR"
    # Only the static libraries Pharos links (step 3): not libduckdb.dylib and
    # not the loadable .duckdb_extension files, which DuckDB builds by default.
    local targets
    targets="$(ninja -C "$BUILD/release" -t targets all \
        | awk -F: '$1 ~ /\/lib[a-z0-9_]+_extension\.a$/ {print $1}' | sort -u)"
    # shellcheck disable=SC2086
    cmake --build "$BUILD/release" --config Release --target duckdb_static duckdb_generated_extension_loader $targets

    # 3. Every static library the app needs, in one folder (DuckDB's gather-libs).
    rm -rf "$OUT"
    mkdir -p "$OUT/lib" "$OUT/include"
    cp "$BUILD/release/src/libduckdb_static.a" "$OUT/lib/"
    cp "$BUILD"/release/third_party/*/libduckdb_*.a "$OUT/lib/"
    cp "$BUILD/release/extension/libduckdb_generated_extension_loader.a" "$OUT/lib/"
    cp "$BUILD"/release/extension/*/lib*_extension.a "$OUT/lib/"
    # Not vcpkg's zlib: the app links macOS's libz (-lz), which minizip-ng uses
    # as well.
    # Not libpq's embedded-SQL libraries (ecpg, pgtypes) or psql's frontend
    # utilities (pgfeutils), which nothing calls.
    for lib in "$BUILD/release/vcpkg_installed/$TRIPLET/lib/"*.a; do
        case "$(basename "$lib")" in
            libz.a|libecpg.a|libecpg_compat.a|libpgtypes.a|libpgfeutils.a) ;;
            *) cp "$lib" "$OUT/lib/" ;;
        esac
    done
    cp "$SRC/src/include/duckdb.h" "$OUT/include/"

    # sqlite_scanner compiles its own SQLite (3.38.1) as C, with global sqlite3_*
    # names; rusqlite links a newer SQLite into the same binary. Rename every
    # sqlite3* symbol inside the extension's archive — its SQLite's definitions and
    # its own references to them — so the two copies never meet.
    OBJCOPY="$(rustc --print sysroot)/lib/rustlib/$(rustc -vV | sed -n 's/^host: //p')/bin/rust-objcopy"
    SQLITE_EXT="$OUT/lib/libsqlite_scanner_extension.a"
    nm -A "$SQLITE_EXT" 2>/dev/null | awk '{print $NF}' | grep -E '^_sqlite3' | sort -u \
        | awk '{ sub(/^_/, "", $1); print "_" $1 " _pharos_ext_" $1 }' > "$BUILD/sqlite-rename.map"
    "$OBJCOPY" --redefine-syms="$BUILD/sqlite-rename.map" "$SQLITE_EXT"
    if nm "$SQLITE_EXT" 2>/dev/null | grep -qE ' [TtUuDdSsBbC] _sqlite3'; then
        echo "build-duckdb: sqlite3 symbols left in $SQLITE_EXT" >&2
        exit 1
    fi
    echo "$STAMP" > "$OUT/stamp"
    echo "build-duckdb: $RUST_TARGET -> $OUT"
    ls -la "$OUT/lib"
}

main "$@"
