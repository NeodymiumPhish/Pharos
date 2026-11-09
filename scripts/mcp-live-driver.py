#!/usr/bin/env python3
"""Drive a running Pharos through `Pharos --mcp`, as an MCP client would.

Used by scripts/live-mcp-check.sh, which launches a re-identified copy of the
app with the MCP server on and a DuckDB connection `mcp-duck` holding a
`people` table of three rows. Prints PASS/FAIL lines; exits 1 on a failure.

Usage: mcp-live-driver.py <Pharos binary> <launcher> <unapproved|cloud|local|unconfirmed>

The launcher (scripts/mcp-fake-client.swift, built by the check) starts the
bridge, so Pharos identifies the "app" by it. The mode says what the check
has set that app to in Settings: not approved yet, Cloud, Local, or Local with
its changes to data and variables let through without asking.
"""
import json
import subprocess
import sys
import time

BIN, LAUNCHER, MODE = sys.argv[1], sys.argv[2], sys.argv[3]
failures = 0


def check(cond, name, detail=""):
    global failures
    if cond:
        print(f"PASS {name}")
    else:
        failures += 1
        print(f"FAIL {name}" + (f"\n  {detail}" if detail else ""))


proc = subprocess.Popen([LAUNCHER, BIN, "--mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
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
check(len(tools) == 20, "tools/list: 20 tools", str(len(tools)))


def finish():
    proc.stdin.close()
    proc.wait(timeout=5)
    print()
    print(f"All live MCP checks passed ({MODE})." if failures == 0 else f"{failures} failure(s).")
    sys.exit(1 if failures else 0)


if MODE == "unapproved":
    for attempt in ("first", "second"):
        got, err = tool("list_tabs")
        check(got is None and "not approved" in (err or ""),
              f"unapproved: the {attempt} tool call from a new app is refused until the user approves it", err or "")
    finish()

if MODE == "cloud":
    conns, err = tool("list_connections")
    ids = sorted(c["id"] for c in (conns or {}).get("connections", []))
    check(ids == ["mcp-duck"], "cloud: only the connection shared with all approved apps is listed", err or str(ids))
    got, err = tool("create_card", connection_id="local-duck", sql="SELECT 1")
    check(got is None and "shared with" in (err or ""), "cloud: a local-only connection is out of reach", err or "")
    made, err = tool("create_card", connection_id="mcp-duck", sql="SELECT count(*) AS n FROM people")
    ran, err = tool("run_card", tab_id=made["tab_id"], card_id=made["card"]["id"])
    check(ran is not None and ran.get("result", {}).get("rows") == [["3"]], "cloud: a read on a shared connection runs",
          err or json.dumps(ran))
    delete, _ = tool("create_card", tab_id=made["tab_id"], sql="DELETE FROM people")
    refused, err = tool("run_card", tab_id=made["tab_id"], card_id=delete["card"]["id"])
    check(refused is None and "change data" in (err or ""), "cloud: writes are for local apps only, so refused", err or "")
    variables, _ = tool("list_variables")
    pv = [v for v in variables["variables"] if v["name"] == "person_id"]
    check(pv and "value" not in pv[0] and variables["values_shared"] is False, "cloud: variable values are for local apps only",
          json.dumps(variables))
    finish()

if MODE == "unconfirmed":
    made, err = tool("create_variable", name="quick_one", type="number", value="7")
    check(made is not None and made["variable"].get("value") == "7", "unconfirmed: create_variable needs no answer",
          err or json.dumps(made))
    if made:
        vid = made["variable"]["id"]
        changed, err = tool("update_variable", variable_id=vid, value="8")
        check(changed is not None and changed["variable"].get("value") == "8", "unconfirmed: update_variable needs no answer",
              err or json.dumps(changed))
        gone, err = tool("delete_variable", variable_id=vid)
        check(gone is not None and gone.get("deleted") is True, "unconfirmed: delete_variable needs no answer", err or "")
        left, _ = tool("list_variables")
        check(not any(v["name"] == "quick_one" for v in left["variables"]), "unconfirmed: the deleted variable is gone",
              json.dumps(left))
    card, err = tool("create_card", connection_id="mcp-duck", sql="DELETE FROM people WHERE id = 1", name="Remove Ada")
    ran, err = tool("run_card", tab_id=card["tab_id"], card_id=card["card"]["id"], wait_seconds=10)
    check(ran is not None and ran.get("status") == "succeeded"
          and ran.get("card", {}).get("last_run", {}).get("rows_affected") == 1,
          "unconfirmed: a DELETE runs without the sheet", err or json.dumps(ran))
    finish()

# MODE == "local": everything below.

conns, err = tool("list_connections")
names = [c["name"] for c in (conns or {}).get("connections", [])]
check("MCP Check" in names, "list_connections: the seeded connection", err or str(names))
check(all("password" not in c and "host" not in c for c in (conns or {}).get("connections", [])),
      "list_connections: no passwords or hosts")

# A connection the user has not shared is out of reach everywhere.
check(not any(c["id"] == "hidden-duck" for c in (conns or {}).get("connections", [])),
      "list_connections: a connection that is not shared is not listed")
check(any(c["id"] == "local-duck" for c in (conns or {}).get("connections", [])),
      "list_connections: a local app also sees the local-only connection")
for name, args in [("connect", {"connection_id": "hidden-duck"}),
                   ("create_tab", {"connection_id": "hidden-duck"}),
                   ("create_card", {"connection_id": "hidden-duck", "sql": "SELECT secret FROM vault"}),
                   ("search_history", {"connection_id": "hidden-duck"}),
                   ("list_variables", {"connection_id": "hidden-duck"}),
                   ("open_session", {"saved_session_id": "hidden-session"})]:
    got, err = tool(name, **args)
    check(got is None and "shared with this app" in (err or ""), f"{name}: refused for a connection that is not shared",
          err or json.dumps(got))
hidden_hist, _ = tool("search_history", search="vault")
check(hidden_hist["entries"] == [], "search_history: the unshared connection's queries are not found",
      json.dumps(hidden_hist))
all_hist, _ = tool("search_history", limit=200)
check(not any(e["connection_id"] == "hidden-duck" for e in all_hist["entries"]),
      "search_history: nor listed without a search")
lib, _ = tool("list_saved_sessions")
check(not any(s["id"] == "hidden-session" for s in lib["saved_sessions"]),
      "list_saved_sessions: a Session on the unshared connection is not listed")
allvars, _ = tool("list_variables")
check(not any(v["name"] == "vault_key" for v in allvars["variables"]),
      "list_variables: a variable linked only to the unshared connection is not listed")

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

# A run that fails, then the history of this run's queries.
bad, err = tool("create_card", tab_id=tab, sql="SELECT * FROM no_such_table", name="Broken Query")
failed, err = tool("run_card", tab_id=tab, card_id=bad["card"]["id"])
check(failed is not None and failed["status"] == "failed" and "no_such_table" in failed.get("error", ""),
      "run_card: a failure comes back with the server's error", err or json.dumps(failed))

hist, err = tool("search_history", search="people", connection_id="mcp-duck")
sqls = [e["sql"] for e in (hist or {}).get("entries", [])]
check(any("ORDER BY id" in q for q in sqls) and any("count(*)" in q for q in sqls),
      "search_history: finds this run's queries by a word of their SQL", err or json.dumps(sqls))
check(all(e["status"] == "succeeded" and "row_count" in e for e in hist["entries"] if "people" in e["sql"]),
      "search_history: each with its status and row count")
fails, err = tool("search_history", status="failed", limit=5)
check(any("no_such_table" in e["sql"] and e.get("error") for e in (fails or {}).get("entries", [])),
      "search_history: status failed finds the failure, with its error", err or json.dumps(fails))
one, _ = tool("search_history", connection_id="mcp-duck", limit=1)
check(len(one["entries"]) == 1 and one["next_offset"] == 1, "search_history: pages, with next_offset")
nobody, err = tool("search_history", connection_id="nope")
check(nobody is None and "list_connections" in (err or ""), "search_history: an unknown connection is refused")

variables, err = tool("list_variables", connection_id="mcp-duck")
pv = [v for v in (variables or {}).get("variables", []) if v["name"] == "person_id"]
check(len(pv) == 1 and pv[0]["type"] == "number" and pv[0]["scope"] == "global",
      "list_variables: the seeded variable, its type and scope", err or json.dumps(variables))
check(pv and pv[0].get("value") == "2" and variables["values_shared"] is True,
      "list_variables: a local app is given values, as Settings allows local apps", json.dumps(variables))

check(pv and pv[0].get("id"), "list_variables: each variable has an id", json.dumps(variables))
# Refused before any sheet is shown, so none of these needs an answer.
bad, err = tool("create_variable", name="has space", type="text", value="x")
check(bad is None and "not a variable name" in (err or ""), "create_variable: a bad name is refused", err or "")
bad, err = tool("create_variable", name="person_id", type="number", value="1")
check(bad is None and "already exists" in (err or ""), "create_variable: a name in use is refused", err or "")
bad, err = tool("create_variable", name="fresh_one", type="number", value="abc")
check(bad is None and "does not fit" in (err or ""), "create_variable: a value that does not fit its type is refused", err or "")
bad, err = tool("create_variable", name="fresh_one", type="nonsense", value="1")
check(bad is None and "must be one of" in (err or ""), "create_variable: an unknown type is refused", err or "")
bad, err = tool("create_variable", name="fresh_one", type="number", value="1", connection_ids=["hidden-duck"])
check(bad is None and "list_connections" in (err or ""), "create_variable: an unshared connection reads as missing", err or "")
bad, err = tool("update_variable", variable_id="00000000-0000-0000-0000-000000000000", value="1")
check(bad is None and "list_variables" in (err or ""), "update_variable: an unknown id is refused", err or "")
if pv:
    bad, err = tool("update_variable", variable_id=pv[0]["id"])
    check(bad is None and "to change" in (err or ""), "update_variable: nothing to change is refused", err or "")

# A valid request shows the sheet. Nobody answers it here: it closes by itself
# and nothing is created.
started = time.monotonic()
unanswered, err = tool("create_variable", name="fresh_one", type="number", value="1")
waited = time.monotonic() - started
check(unanswered is None and "did not answer" in (err or ""), "create_variable: an unanswered sheet closes and says so",
      f"answered after {waited:.1f}s: {err or json.dumps(unanswered)}")
check(waited > 40, "create_variable: the sheet waits for the user", f"answered after {waited:.1f}s")
afterwards, _ = tool("list_variables")
check(not any(v["name"] == "fresh_one" for v in afterwards["variables"]),
      "create_variable: an unanswered sheet creates nothing", json.dumps(afterwards))

withvar, _ = tool("create_card", tab_id=tab, sql="SELECT name FROM people WHERE id = {{person_id}}", name="Person By Id")
filled, err = tool("run_card", tab_id=tab, card_id=withvar["card"]["id"])
check(filled is not None and filled.get("result", {}).get("rows") == [["Grace"]],
      "run_card: a {{variable}} is filled in from the user's variables", err or json.dumps(filled))
unknown, _ = tool("create_card", tab_id=tab, sql="SELECT {{no_such_var}}")
missing_var, err = tool("run_card", tab_id=tab, card_id=unknown["card"]["id"])
check(missing_var is None and "no_such_var" in (err or ""), "run_card: an undefined variable is refused by name", err or "")

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

finish()
