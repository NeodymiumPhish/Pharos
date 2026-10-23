#!/bin/bash
# Write the licence notices for all third-party code linked into Pharos.
#
#   scripts/gen-third-party-notices.sh            write the two files
#   scripts/gen-third-party-notices.sh --check    fail if either file is stale
#
# Outputs (one source, two forms):
#   THIRD_PARTY_NOTICES.md           the repository's notices (linked from README)
#   Pharos/Files/Acknowledgements.txt  bundled; Settings ▸ About ▸ Show Notices
#
# Sources, all read from local files:
#   - DuckDB and every third-party folder its build compiles or includes
#     (scripts/build-duckdb.sh's build tree: build.ninja says what is used)
#   - each out-of-tree DuckDB extension repository, and licence files inside it
#   - each vcpkg port the app links (share/<port>/copyright)
#   - every Rust crate linked into libpharos_core.a (cargo metadata: normal
#     dependencies of pharos-core, without proc-macros and build scripts), with
#     the licence files the published crate ships
#
# Needs the arm64 DuckDB build (scripts/build-duckdb.sh arm64) and a cargo
# registry with pharos-core's dependencies (any cargo build fetches them).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${PHAROS_DUCKDB_WORK:-$ROOT/pharos-core/target/duckdb-build}"
MODE="${1:-write}"
# The version folders build-duckdb.sh uses (src-<tag>, build-<tag>-arm64).
DUCKDB_TAG="$(sed -n 's/^ *DUCKDB_TAG="\(.*\)"$/\1/p' "$ROOT/scripts/build-duckdb.sh")"
[ -n "$DUCKDB_TAG" ] || { echo "gen-third-party-notices: no DUCKDB_TAG in scripts/build-duckdb.sh" >&2; exit 1; }

METADATA="$(mktemp)"
trap 'rm -f "$METADATA"' EXIT
(cd "$ROOT/pharos-core" && cargo metadata --format-version 1 --locked \
    --filter-platform aarch64-apple-darwin > "$METADATA")

python3 -I - "$ROOT" "$WORK" "$METADATA" "$MODE" "$DUCKDB_TAG" <<'PY'
import hashlib, json, os, re, sys

root, work, metadata_path, mode, duckdb_tag = sys.argv[1:6]
src = os.path.join(work, "src-" + duckdb_tag)
build = os.path.join(work, "build-" + duckdb_tag + "-arm64", "release")
deps = os.path.join(build, "_deps")
triplet = "arm64-osx-pharos"

LICENCE_FILE = re.compile(r"^(licen[cs]e|copying|notice|notices|unlicense|copyright)([-_.][\w.-]*)?$", re.I)

def fail(msg):
    sys.exit("gen-third-party-notices: " + msg)

def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return shorten_apache(f.read().replace("\r\n", "\n").strip("\n") + "\n")

def licence_files(folder, depth=2):
    """Licence files in `folder` and up to `depth` levels below it."""
    found = []
    base = folder.rstrip("/").count("/")
    for here, dirs, files in os.walk(folder):
        dirs[:] = sorted(d for d in dirs if d not in (".git", "test", "tests", "duckdb", "extension-ci-tools"))
        if here.count("/") - base >= depth:
            dirs[:] = []
        for f in sorted(files):
            if LICENCE_FILE.match(f):
                found.append(os.path.join(here, f))
    return found

for need in (src, build):
    if not os.path.isdir(need):
        fail(f"no DuckDB build in {work}. Run scripts/build-duckdb.sh arm64 first.")

ninja = open(os.path.join(build, "build.ninja"), encoding="utf-8", errors="replace").read()
version = re.search(r"-DDUCKDB_MAJOR_VERSION=(\d+) -DDUCKDB_MINOR_VERSION=(\d+) -DDUCKDB_PATCH_VERSION=(\d+)", ninja)
duckdb_version = ".".join(version.groups()) if version else "?"

# The Apache License 2.0 terms are the same in every copy, so the file gives
# them once (section "Apache License 2.0") and each copy keeps only what is its
# own: a copyright line before the terms, an exception after them.
APACHE_START = re.compile(r"^\s*Apache License\s*\n\s*Version 2\.0,? January 2004", re.M)
APACHE_TERMS_END = "END OF TERMS AND CONDITIONS"
APACHE_APPENDIX_END = "limitations under the License."
apache_terms = None

def shorten_apache(text):
    global apache_terms
    start = APACHE_START.search(text)
    end = text.find(APACHE_TERMS_END)
    if not start or end < 0:
        return text
    terms = text[start.start():end + len(APACHE_TERMS_END)]
    if apache_terms is None or len(terms) > len(apache_terms):
        apache_terms = terms.strip("\n") + "\n"
    before = text[:start.start()].strip()
    after = text[end + len(APACHE_TERMS_END):]
    appendix = after.find(APACHE_APPENDIX_END)
    if "APPENDIX" in after[:200] and appendix >= 0:
        after = after[appendix + len(APACHE_APPENDIX_END):]
    after = after.strip()
    parts = [before] if before else []
    parts.append("Apache License, Version 2.0 (the terms are under \"Apache License 2.0\" at the end of this file).")
    if after:
        parts.append(after)
    return "\n\n".join(parts) + "\n"

# ---- C and C++ -------------------------------------------------------------

native = []   # (title, detail, [licence texts])

native.append(("DuckDB " + duckdb_version, "https://github.com/duckdb/duckdb — MIT License",
               [read(os.path.join(src, "LICENSE"))]))

def used(rel):
    """True when the DuckDB build compiles or includes code from `rel`."""
    return re.search(re.escape(rel) + r"(/|\s|$)", ninja) is not None

third_party = []
for parent in [os.path.join(src, "third_party")] + sorted(
        os.path.join(src, "extension", e, "third_party") for e in os.listdir(os.path.join(src, "extension"))
        if os.path.isdir(os.path.join(src, "extension", e, "third_party"))):
    if not os.path.isdir(parent):
        continue
    for name in sorted(os.listdir(parent)):
        folder = os.path.join(parent, name)
        if os.path.isdir(folder) and used(os.path.relpath(folder, src)):
            third_party.append((name, folder))
for name, folder in third_party:
    files = licence_files(folder)
    if not files:
        fail(f"{folder} is linked but has no licence file; add it to the script by hand")
    native.append((f"{name} (in DuckDB)", os.path.relpath(folder, src), [read(f) for f in files]))

EXTENSIONS = {  # folder in _deps → (name, repository)
    "inet_extension_fc-src": ("DuckDB inet extension", "https://github.com/duckdb/duckdb-inet"),
    "fts_extension_fc-src": ("DuckDB fts extension", "https://github.com/duckdb/duckdb-fts"),
    "excel_extension_fc-src": ("DuckDB excel extension", "https://github.com/duckdb/duckdb-excel"),
    "sqlite_scanner_extension_fc-src": ("DuckDB sqlite extension", "https://github.com/duckdb/duckdb-sqlite"),
    "httpfs_extension_fc-src": ("DuckDB httpfs extension", "https://github.com/duckdb/duckdb-httpfs"),
    "postgres_scanner_extension_fc-src": ("DuckDB postgres extension", "https://github.com/duckdb/duckdb-postgres"),
}
built = {d for d in os.listdir(deps) if d.endswith("_extension_fc-src")}
if built != set(EXTENSIONS):
    fail(f"extension list differs from the build: missing {sorted(built - set(EXTENSIONS))}, "
         f"stale {sorted(set(EXTENSIONS) - built)}")
for folder, (title, repo) in EXTENSIONS.items():
    path = os.path.join(deps, folder)
    if not os.path.isdir(path):
        fail(f"{path} is missing; the extension list changed?")
    files = licence_files(path, depth=4)
    if not files:
        fail(f"{path} has no licence file")
    native.append((title, repo, [read(f) for f in files]))

SQLITE_PD = "The SQLite source code is in the public domain. The authors disclaim copyright to it.\n"
native.append(("SQLite 3.38.1 (in the DuckDB sqlite extension)", "https://www.sqlite.org/copyright.html", [SQLITE_PD]))

ports = os.path.join(build, "vcpkg_installed", triplet, "share")
for port in sorted(os.listdir(ports)) if os.path.isdir(ports) else []:
    if port.startswith("vcpkg-") or port == "zlib":   # build helpers; zlib is macOS's own
        continue
    copyright = os.path.join(ports, port, "copyright")
    if os.path.isfile(copyright):
        native.append((f"{port} (for DuckDB's extensions)", "vcpkg port " + port, [read(copyright)]))

# ---- Rust --------------------------------------------------------------------

meta = json.load(open(metadata_path))
packages = {p["id"]: p for p in meta["packages"]}
nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
linked, stack = set(), [meta["resolve"]["root"]]
while stack:
    for dep in nodes[stack.pop()]["deps"]:
        if not any(k["kind"] is None for k in dep["dep_kinds"]):
            continue          # dev and build dependencies are not linked
        pkg = packages[dep["pkg"]]
        if any("proc-macro" in t["kind"] for t in pkg["targets"]):
            continue          # runs inside rustc only
        if dep["pkg"] not in linked:
            linked.add(dep["pkg"])
            stack.append(dep["pkg"])

MIT = """Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

crates = []   # (name, version, licence, repository, [texts])
missing = []
for pid in linked:
    p = packages[pid]
    folder = os.path.dirname(p["manifest_path"])
    files = [f for f in licence_files(folder, depth=0)]
    texts = [read(f) for f in files]
    if p.get("license_file"):
        lf = os.path.join(folder, p["license_file"])
        if os.path.isfile(lf) and lf not in files:
            texts.append(read(lf))
    if not texts:
        if "MIT" in (p.get("license") or ""):
            who = ", ".join(p.get("authors") or []) or f"the {p['name']} authors"
            texts = [f"MIT License (the crate ships no licence file)\n\nCopyright (c) {who}\n\n" + MIT]
        else:
            missing.append(f"{p['name']} {p['version']} ({p.get('license')})")
            continue
    crates.append((p["name"], p["version"], p.get("license") or "?", p.get("repository") or "", texts))
if missing:
    fail("no licence text for: " + "; ".join(sorted(missing)))
crates.sort(key=lambda c: (c[0], c[1]))
sqlite_sys = [v for n, v, _, _, _ in crates if n == "libsqlite3-sys"]
if sqlite_sys:
    native.append((f"SQLite (bundled in the Rust crate libsqlite3-sys {sqlite_sys[0]}, for Pharos's own data)",
                   "https://www.sqlite.org/copyright.html", [SQLITE_PD]))

# Crates with the same texts share one copy.
groups = {}
for c in crates:
    key = hashlib.sha256("\0".join(c[4]).encode()).hexdigest()
    groups.setdefault(key, []).append(c)
ordered = sorted(groups.values(), key=lambda g: (g[0][0], g[0][1]))

# ---- Write -------------------------------------------------------------------

INTRO = ("Pharos is distributed under its own licence (LICENSE). It contains the "
         "third-party software below, each under its own licence. This file is "
         "generated by scripts/gen-third-party-notices.sh; do not edit it.")

def render(md):
    out = []
    h1 = (lambda t: f"# {t}\n") if md else (lambda t: f"{t}\n{'=' * len(t)}\n")
    h2 = (lambda t: f"## {t}\n") if md else (lambda t: f"{t}\n{'-' * len(t)}\n")
    h3 = (lambda t: f"### {t}\n") if md else (lambda t: f"* {t}\n")
    def text(t):
        return f"```text\n{t}```\n" if md else "\n" + t
    out.append(h1("Pharos — Third-Party Notices"))
    out.append(INTRO + "\n")
    out.append(h2("Contents"))
    out.append(f"- DuckDB {duckdb_version}, its extensions and their C/C++ libraries ({len(native)} entries)\n"
               f"- Rust crates linked into pharos-core ({len(crates)} crates)\n")
    out.append(h2("DuckDB, its extensions and their libraries"))
    for title, detail, texts in native:
        out.append(h3(title))
        out.append(detail + "\n")
        for t in texts:
            out.append(text(t))
    out.append(h2("Rust crates"))
    for group in ordered:
        names = ", ".join(f"{n} {v}" for n, v, _, _, _ in group)
        out.append(h3(names))
        licences = sorted({l for _, _, l, _, _ in group})
        repos = sorted({r for _, _, _, r, _ in group if r})
        out.append("Licence: " + "; ".join(licences) + ("\n" if not repos else "  \nSource: " + ", ".join(repos) + "\n"))
        for t in group[0][4]:
            out.append(text(t))
    if apache_terms:
        out.append(h2("Apache License 2.0"))
        out.append("The terms that every Apache-2.0 entry above refers to.\n")
        out.append(text(apache_terms))
    return "\n".join(out)

targets = {
    os.path.join(root, "THIRD_PARTY_NOTICES.md"): render(True),
    os.path.join(root, "Pharos", "Files", "Acknowledgements.txt"): render(False),
}
stale = []
for path, body in targets.items():
    old = open(path, encoding="utf-8").read() if os.path.exists(path) else None
    if mode == "--check":
        if old != body:
            stale.append(os.path.relpath(path, root))
    else:
        with open(path, "w", encoding="utf-8") as f:
            f.write(body)
        print(f"gen-third-party-notices: {os.path.relpath(path, root)} ({len(body) // 1024} KB)")
if stale:
    fail("stale: " + ", ".join(stale) + " — run scripts/gen-third-party-notices.sh")
if mode == "--check":
    print(f"gen-third-party-notices: up to date ({len(native)} native entries, {len(crates)} crates)")
PY
