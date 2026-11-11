#!/bin/bash
# Packs Pharos's MCP server as a Claude desktop extension (.mcpb).
#
# Usage: scripts/build-mcpb.sh <Pharos.app> [output.mcpb]
#
# The extension holds no copy of Pharos: its server is extension/pharos-mcp,
# which finds the installed Pharos.app and runs `Pharos --mcp`, the same
# command a hand-written claude_desktop_config.json entry runs. An org Owner
# can upload it under Claude's Organization settings ▸ Connectors ▸ Desktop,
# which works where "Allow local MCP servers" is off (docs/mcp.md).
#
# The manifest's version is the app's CFBundleShortVersionString, and its
# tool list is what that app's bridge answers to tools/list, so the two can't
# drift. The bridge is pointed at a socket that doesn't exist, so it answers
# from its own catalog and never reaches a running Pharos.
#
# Then the packed file is checked: unzipped, its launcher is run the way
# Claude runs it, and its tools/list must match the manifest.
#
# Needs npx (Node), for @anthropic-ai/mcpb.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: $0 <Pharos.app> [output.mcpb]}"
APP="$(cd "$APP" && pwd)"
BIN="$APP/Contents/MacOS/Pharos"
[ -x "$BIN" ] || { echo "not an app bundle: $APP" >&2; exit 2; }
command -v npx >/dev/null || { echo "needs npx (brew install node)" >&2; exit 2; }
MCPB=(npx --yes @anthropic-ai/mcpb@2.1.2)

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="${2:-build/Pharos-$VERSION.mcpb}"
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pharos-mcpb.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/server"

tools_list() {  # $1: the command that starts the bridge
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' |
        PHAROS_MCP_SOCKET="$WORK/no-such.sock" "$@"
}

tools_list "$BIN" --mcp > "$WORK/tools.json"

cp extension/pharos-mcp "$STAGE/server/pharos-mcp"
chmod 755 "$STAGE/server/pharos-mcp"
cp docs/assets/images/pharos-logo.png "$STAGE/icon.png"

python3 -I - "$WORK/tools.json" "$VERSION" "$STAGE/manifest.json" <<'PY'
import json, re, sys

tools_path, version, out = sys.argv[1:]
tools = json.load(open(tools_path))["result"]["tools"]

def first_sentence(text):
    m = re.match(r"(.+?\.)(\s|$)", text)
    return m.group(1) if m else text

manifest = {
    "manifest_version": "0.3",
    "name": "pharos",
    "display_name": "Pharos",
    "version": version,
    "description": "Work with your Pharos query cards: list connections and tabs, add and run cards, and read their rows.",
    "long_description": (
        "Connects Claude to the Pharos app on this Mac. Everything happens in your Pharos window: "
        "a card Claude adds appears in the tab, a run shows its progress, and statements that change "
        "data need your permission and your confirmation.\n\n"
        "Pharos must be installed and running, with Settings ▸ Security & Privacy ▸ Allow AI apps to "
        "use Pharos turned on. The first tool call adds Claude to Pharos's AI apps list; choose Cloud "
        "for it there. Then share connections with AI apps in File ▸ Manage Connections."
    ),
    "author": {"name": "NeodymiumPhish", "url": "https://github.com/NeodymiumPhish"},
    "homepage": "https://github.com/NeodymiumPhish/Pharos",
    "documentation": "https://neodymiumphish.github.io/Pharos/mcp.html",
    "support": "https://github.com/NeodymiumPhish/Pharos/issues",
    "icon": "icon.png",
    "server": {
        "type": "binary",
        "entry_point": "server/pharos-mcp",
        "mcp_config": {
            # Through /bin/sh, so the launcher runs whether or not the
            # unpacked file kept its executable bit.
            "command": "/bin/sh",
            "args": ["${__dirname}/server/pharos-mcp"],
            "env": {},
        },
    },
    "tools": [{"name": t["name"], "description": first_sentence(t["description"])} for t in tools],
    "tools_generated": False,
    "keywords": ["sql", "postgresql", "duckdb", "database", "query"],
    "compatibility": {"platforms": ["darwin"]},
}
with open(out, "w") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"manifest: {len(tools)} tools, version {version}")
PY

"${MCPB[@]}" validate "$STAGE/manifest.json"
rm -f "$OUT"
"${MCPB[@]}" pack "$STAGE" "$OUT"

# Check the packed file the way Claude runs it.
mkdir "$WORK/unpacked"
unzip -q "$OUT" -d "$WORK/unpacked"
tools_list env PHAROS_APP="$APP" /bin/sh "$WORK/unpacked/server/pharos-mcp" > "$WORK/packed-tools.json"
python3 -I - "$WORK/unpacked/manifest.json" "$WORK/packed-tools.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
answered = json.load(open(sys.argv[2]))["result"]["tools"]
listed = [t["name"] for t in manifest["tools"]]
served = [t["name"] for t in answered]
if listed != served:
    sys.exit(f"FAIL: the manifest lists {listed}, the launcher served {served}")
print(f"ok: the packed launcher serves the manifest's {len(served)} tools")
PY

echo "$OUT"
