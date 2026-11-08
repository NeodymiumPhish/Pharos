#!/usr/bin/env python3
"""Drive a running Pharos through `Pharos --mcp`, as an MCP client would.

Used by scripts/live-mcp-check.sh, which launches a re-identified copy of the
app with the MCP server on and a DuckDB connection `mcp-duck` holding a
`people` table of three rows. Prints PASS/FAIL lines; exits 1 on a failure.

Usage: mcp-live-driver.py <path to Pharos binary>
"""
import json
import subprocess
import sys

BIN = sys.argv[1]
failures = 0


def check(cond, name, detail=""):
    global failures
    if cond:
        print(f"PASS {name}")
    else:
        failures += 1
        print(f"FAIL {name}" + (f"\n  {detail}" if detail else ""))


proc = subprocess.Popen([BIN, "--mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
next_id = 0


def rpc(method, params=None):
    global next_id
    next_id += 1
    msg = {"jsonrpc": "2.0", "id": next_id, "method": method}
    if params is not None:
        msg["params"] = params
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    while True:
        line = proc.stdout.readline()
        if not line:
            raise SystemExit("FAIL the bridge closed its output")
        reply = json.loads(line)
        if reply.get("id") == next_id:
            return reply


def tool(tool_name, /, **args):
    """(structured result or None, error text or None)."""
    reply = rpc("tools/call", {"name": tool_name, "arguments": args})
    result = reply.get("result", {})
    text = result.get("content", [{}])[0].get("text", "")
    if result.get("isError") or "error" in reply:
        return None, text or json.dumps(reply.get("error"))
    return result.get("structuredContent"), None


init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                          "clientInfo": {"name": "Live Check", "version": "1"}})
proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
proc.stdin.flush()
check(init["result"]["serverInfo"]["name"] == "pharos", "initialize: Pharos answers")

tools = rpc("tools/list")["result"]["tools"]
check(len(tools) == 15, "tools/list: 15 tools", str(len(tools)))

conns, err = tool("list_connections")
names = [c["name"] for c in (conns or {}).get("connections", [])]
check("MCP Check" in names, "list_connections: the seeded connection", err or str(names))
check(all("password" not in c and "host" not in c for c in (conns or {}).get("connections", [])),
      "list_connections: no passwords or hosts")

made, err = tool("create_card", connection_id="mcp-duck", sql="SELECT id, name FROM people ORDER BY id",
                 name="People By Id")
check(made is not None, "create_card: a new tab on the connection", err or "")
if made is None:
    sys.exit(1)
tab, card = made["tab_id"], made["card"]["id"]
check(made["card"]["status"] == "never_run" and made["card"]["name"] == "People By Id",
      "create_card: the card, not run", json.dumps(made["card"]))

tabs, _ = tool("list_tabs")
check(any(t["id"] == tab and t["connection_id"] == "mcp-duck" for t in tabs["tabs"]),
      "list_tabs: the new tab, on the connection")

ran, err = tool("run_card", tab_id=tab, card_id=card, wait_seconds=30, limit=10)
check(ran is not None and ran["status"] == "succeeded", "run_card: succeeds", err or json.dumps(ran))
if ran:
    res = ran.get("result", {})
    check([c["name"] for c in res.get("columns", [])] == ["id", "name"], "run_card: the columns", json.dumps(res))
    check(res.get("rows") == [["1", "Ada"], ["2", "Grace"], ["3", "Edsger"]], "run_card: the rows, as text",
          json.dumps(res.get("rows")))

page, err = tool("get_card_result", tab_id=tab, card_id=card, offset=1, limit=1)
check(page is not None and page["result"]["rows"] == [["2", "Grace"]] and page["result"]["next_offset"] == 2,
      "get_card_result: one page, and where the next starts", err or json.dumps(page))

edited, err = tool("update_card", tab_id=tab, card_id=card, sql="SELECT count(*) AS n FROM people")
check(edited is not None and edited["card"]["sql"].startswith("SELECT count"), "update_card: the SQL changes", err or "")
rerun, err = tool("run_card", tab_id=tab, card_id=card, limit=5)
check(rerun is not None and rerun["status"] == "succeeded" and rerun["card_id"] != card,
      "run_card: an edited card that ran before lands on a new version", err or json.dumps(rerun))
check(rerun is not None and rerun.get("result", {}).get("rows") == [["3"]], "run_card: the new version's rows",
      json.dumps(rerun))

locked, err = tool("update_card", tab_id=tab, card_id=card, sql="SELECT 1")
check(locked is None and "locked" in (err or ""), "update_card: a locked version refuses new SQL", err or "")

cards, _ = tool("list_cards", tab_id=tab)
versions = [(c["version"], c["locked"]) for c in cards["cards"]]
check(versions == [(1, True), (2, False)], "list_cards: version 1 locked, version 2 current", str(versions))

missing, err = tool("get_card", tab_id=tab, card_id="no-such-card")
check(missing is None and "list_cards" in (err or ""), "get_card: an unknown card says what to call", err or "")

typo, err = tool("get_card", tab_id=tab, cardid=card)
check(typo is None and "card_id" in (err or ""), "tools/call: a misspelt argument is refused", err or "")

saved, err = tool("save_session", tab_id=tab, name="MCP Check Session", folder="Checks")
check(saved is not None and saved.get("saved_session_id"), "save_session: a new Session", err or "")
library, _ = tool("list_saved_sessions", search="mcp check")
check(any(s["name"] == "MCP Check Session" and s["folder"] == "Checks" and s["open_tab_id"] == tab
          for s in library["saved_sessions"]), "list_saved_sessions: the Session, open in the tab",
      json.dumps(library))
again, err = tool("save_session", tab_id=tab)
check(again is not None and again["saved_session_id"] == saved["saved_session_id"],
      "save_session: a bound tab saves in place", err or json.dumps(again))

idle, _ = tool("cancel_card", tab_id=tab, card_id=card)
check("not running" in (idle or {}).get("message", ""), "cancel_card: an idle card was not running")

# Writes are allowed in this run's settings and Settings ▸ Query's own
# confirmation is OFF: an MCP run must still wait for the user.
delete, err = tool("create_card", tab_id=tab, sql="DELETE FROM people WHERE id = 3", name="Remove Edsger")
check(delete is not None, "create_card: a DELETE card", err or "")
pending, err = tool("run_card", tab_id=tab, card_id=delete["card"]["id"], wait_seconds=3)
check(pending is not None and pending["status"] == "awaiting_confirmation",
      "run_card: a DELETE waits for the user's confirmation, even with Settings' confirmation off",
      err or json.dumps(pending))
followed, _ = tool("get_card", tab_id=tab, card_id=delete["card"]["id"])
check(followed["card"]["status"] == "awaiting_confirmation", "get_card: still awaiting confirmation")
blocked, err = tool("cancel_card", tab_id=tab, card_id=delete["card"]["id"])
check(blocked is None and "confirmation" in (err or ""), "cancel_card: only the user can answer the sheet", err or "")

proc.stdin.close()
proc.wait(timeout=5)
print()
print("All live MCP checks passed." if failures == 0 else f"{failures} failure(s).")
sys.exit(1 if failures else 0)
