#!/bin/bash
# Compare the C/C++ libraries compiled into Pharos with their latest upstream
# releases. Run it before every release (SECURITY.md, "Bundled libraries").
#
#   scripts/check-vendored-versions.sh
#
# Pinned versions come from scripts/build-duckdb.sh (DuckDB, vcpkg); library
# versions come from what vcpkg installed into each build tree
# (build-<arch>/release/vcpkg_installed/vcpkg/info), not from the vcpkg
# checkout's ports: an extension's overlay port can win over vcpkg's port.
# When the architectures differ, the oldest version is shown and the
# difference is reported. Latest versions come from read-only GETs
# (/usr/bin/curl): the GitHub releases API and postgresql.org's versions.json.
# DuckDB, OpenSSL and libpq are compared with the newest release of the SAME
# series (DuckDB/OpenSSL x.y, PostgreSQL major), which is where security fixes
# land; a newer series is reported but is a planned upgrade, not a fix.
#
# Exit status: 0 all current, 1 something is behind or the build trees differ,
# 2 a lookup failed or a library is not installed.
# Needs scripts/build-duckdb.sh to have built at least one architecture.
set -euo pipefail

main() {
    local root work
    root="$(cd "$(dirname "$0")/.." && pwd)"
    work="${PHAROS_DUCKDB_WORK:-$root/pharos-core/target/duckdb-build}"

    python3 -I - "$root/scripts/build-duckdb.sh" "$work" <<'PY'
import glob, json, os, re, subprocess, sys

script, work = sys.argv[1], sys.argv[2]
text = open(script).read()

def pinned_var(name):
    m = re.search(rf'^\s*{name}="([^"]+)"', text, re.M)
    return m.group(1) if m else "?"

def numbers(v):
    return tuple(int(x) for x in re.findall(r"\d+", v))

# vcpkg keeps one info/<port>_<version>_<triplet>.list per installed port;
# port names and triplets have no "_".
installed = {}   # port -> {triplet: version}
trees = glob.glob(os.path.join(work, "build-*", "release", "vcpkg_installed", "vcpkg", "info"))
for info in trees:
    for f in os.listdir(info):
        if f.endswith(".list"):
            port, rest = f[:-len(".list")].split("_", 1)
            version, triplet = rest.rsplit("_", 1)
            installed.setdefault(port, {})[triplet] = version
if not installed:
    print(f"check-vendored-versions: no vcpkg_installed in {work}/build-*; run scripts/build-duckdb.sh first", file=sys.stderr)
    sys.exit(2)

def port_version(port):
    """The oldest version any build tree has, or None when none has the port."""
    by_triplet = installed.get(port)
    if not by_triplet:
        return None
    if len(set(by_triplet.values())) > 1:
        differ.append(f"{port}: " + ", ".join(f"{t} {v}" for t, v in sorted(by_triplet.items())))
    return min(by_triplet.values(), key=numbers)

differ = []

def get(url):
    # /usr/bin/curl, not urllib: it uses the macOS trust store, which a
    # Homebrew or python.org Python may not have.
    out = subprocess.run(["/usr/bin/curl", "-fsSL", "--max-time", "20",
                          "-H", "User-Agent: pharos-check-vendored-versions",
                          "-H", "Accept: application/vnd.github+json", url],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or f"curl exit {out.returncode}")
    return json.loads(out.stdout)

def latest_release(repo):
    return get(f"https://api.github.com/repos/{repo}/releases/latest")["tag_name"]

def libpq_latest(pinned):
    major = str(numbers(pinned)[0])
    for row in get("https://www.postgresql.org/versions.json"):
        if str(row["major"]) == major:
            return f'{row["major"]}.{row["latestMinor"]}'
    raise RuntimeError(f"PostgreSQL {major} is not listed (end of life?)")

def releases(repo):
    rows = get(f"https://api.github.com/repos/{repo}/releases?per_page=100")
    # At least major.minor: very old one-number tags (lz4's r131) sort wrong.
    return [r["tag_name"] for r in rows
            if not r.get("prerelease") and not r.get("draft") and len(numbers(r["tag_name"])) >= 2]

def newest_in_series(tags, pinned, depth):
    """The newest tag whose first `depth` numbers match the pinned version."""
    want = numbers(pinned)[:depth]
    same = [t for t in tags if numbers(t)[:depth] == want]
    return max(same, key=numbers) if same else None

# name, pinned, GitHub repo (None: libpq), series depth (numbers that must
# match for a security update in the same line; 0 = any newer release).
checks = [
    ("DuckDB", pinned_var("DUCKDB_TAG"), "duckdb/duckdb", 2),
    ("vcpkg", pinned_var("VCPKG_TAG"), "microsoft/vcpkg", 0),
    ("OpenSSL", port_version("openssl"), "openssl/openssl", 2),
    ("curl", port_version("curl"), "curl/curl", 0),
    ("libpq", port_version("libpq"), None, 1),
    ("lz4", port_version("lz4"), "lz4/lz4", 0),
    ("expat", port_version("expat"), "libexpat/libexpat", 0),
    ("minizip-ng", port_version("minizip-ng"), "zlib-ng/minizip-ng", 0),
]

def plain(tag):
    return ".".join(str(n) for n in numbers(tag)) if tag else "-"

behind = failed = 0
print(f"{'library':<12} {'pinned':<12} {'same series':<13} {'newest':<12} status")
for name, pinned, repo, depth in checks:
    if pinned is None:
        print(f"{name:<12} {'-':<12} {'?':<13} {'?':<12} NOT INSTALLED (no build tree has the port)")
        failed += 1
        continue
    try:
        if repo is None:
            series = newest = libpq_latest(pinned)
        else:
            tags = releases(repo)
            newest = max(tags, key=numbers)
            series = newest_in_series(tags, pinned, depth) if depth else newest
    except Exception as e:  # network, rate limit, renamed release
        print(f"{name:<12} {pinned:<12} {'?':<13} {'?':<12} LOOKUP FAILED ({e})")
        failed += 1
        continue
    if series and numbers(series) > numbers(pinned):
        status = "BEHIND (same series)" if depth else "BEHIND"
        behind += 1
    elif numbers(newest) > numbers(pinned):
        status = "current in its series; newer series exists"
    else:
        status = "current"
    print(f"{name:<12} {plain(pinned):<12} {plain(series):<13} {plain(newest):<12} {status}")

triplets = sorted({t for by_triplet in installed.values() for t in by_triplet})
print(f"\nLibrary versions are the oldest installed in: {', '.join(triplets)}.")
if differ:
    print("The build trees differ; run scripts/build-duckdb.sh for each architecture:")
    for line in differ:
        print(f"  {line}")
    behind += 1
if failed:
    sys.exit(2)
if behind:
    print("\nA newer release exists. For OpenSSL, curl or libpq read its notes for security fixes;"
          " SECURITY.md says how to update.")
    sys.exit(1)
PY
}

main "$@"
