---
layout: default
title: AI Apps (MCP)
nav_order: 24
---

# AI Apps (MCP)
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

Pharos has a built-in [Model Context Protocol](https://modelcontextprotocol.io) (MCP)
server. An AI app on the same Mac that speaks MCP, such as Claude desktop or LM
Studio, can then work with your query cards:

- list your connections, your open tabs, your saved Sessions and your recent workspaces
- search your query history, and list your query variables
- open a saved Session or a workspace in a tab
- add a query card to a tab, and change its SQL, name or notes
- run a card, and read its status and its rows, a page at a time
- save a tab as a saved Session

Everything the app does happens in your Pharos window. A card it adds appears in
the tab's card stack, a run shows its progress and its results as usual, and a
short notice in the window names the app, for example "Claude added a card".

The server is **off** until you turn it on.

---

## Turning it on

1. Open **Settings ▸ Security & Privacy**.
2. Turn on **Allow AI apps to use Pharos**. The caption under it shows which apps
   are connected.
3. If the app should be able to change data, also turn on **Let AI apps run
   statements that change data** (see [Safety](#safety)).
4. If the app should see your query variables' values, also turn on **Let AI
   apps read query variable values**.
5. Click **Copy** beside **Configuration for your AI app**. This puts the
   configuration below on the clipboard, with the path of your copy of Pharos.

Pharos must be running for an AI app to use it. If Pharos is not running, or the
setting is off, the app still lists Pharos's tools. A tool call then returns a
message that tells you to open Pharos and turn on the setting. You do not have to
restart the AI app after you open Pharos: its next tool call reaches Pharos.

---

## Adding Pharos to an AI app

An MCP app starts Pharos's MCP command, `Pharos --mcp`, and talks to it on its
standard input and output. That command does not open a window. It only carries
messages between the AI app and the running Pharos.

The configuration is the same for Claude desktop and LM Studio:

```json
{
  "mcpServers": {
    "pharos": {
      "command": "/Applications/Pharos.app/Contents/MacOS/Pharos",
      "args": ["--mcp"]
    }
  }
}
```

If Pharos is not in `/Applications`, change the path. **Copy** in Settings
puts in the correct path for you.

### Claude desktop

1. In Claude, open **Settings ▸ Developer** and click **Edit Config**. This opens
   `~/Library/Application Support/Claude/claude_desktop_config.json`.
2. Add the `pharos` entry to `mcpServers`. If the file already has an
   `mcpServers` object, add `"pharos": { … }` inside it, beside the other
   servers.
3. Save the file and quit and reopen Claude.
4. Pharos's tools are now in the tools menu of the message box.

### LM Studio

1. In LM Studio, open the **Program** tab in the right-hand sidebar, click
   **Install ▸ Edit mcp.json**. This opens `~/.lmstudio/mcp.json`.
2. Add the `pharos` entry to `mcpServers`, and save.
3. Turn on the **mcp/pharos** integration in a chat. Use a model that supports
   tool use.

### Other MCP clients

Any client that can start a local (stdio) MCP server can use the same command and
argument. Pharos supports MCP protocol versions 2025-06-18, 2025-03-26 and
2024-11-05.

---

## Safety

**Only your user account can connect.** Pharos does not listen on a network port.
The running app listens on a Unix socket at
`~/Library/Application Support/com.pharos.client/MCP/pharos.sock`, in a folder
that only your user account can open (`0700`). The socket itself is `0600`, and
Pharos also checks that each connecting process runs as your user. A web page,
another computer, or another user on this Mac cannot reach the server.

**Statements that change data are refused unless you allow them.** By default,
an AI app cannot run a card whose SQL contains `INSERT`, `UPDATE`, `DELETE`,
`DROP`, `ALTER`, `TRUNCATE` or `GRANT`. Pharos refuses the run before it is
queued, and tells the app that you can allow it in Settings. Pharos uses the
same check for its own [destructive-query confirmation](query-execution.md). The
check looks at the SQL after query variables are filled in, and it finds these
words even inside a CTE.

**You confirm every change.** If you turn on **Let AI apps run statements that
change data**, each such run still shows Pharos's confirmation sheet. The sheet
names the app that asked for the run, and Pharos bounces its Dock icon so that
you see the sheet. A run that an AI app asks for always shows the sheet, even
if you turned off the confirmation for your own runs in **Settings ▸ Query**.
While the sheet is open, the app sees the status `awaiting_confirmation`. Only
you can answer the sheet. The app cannot press **Run**, and it cannot cancel the
run for you.

**The app sees only what it asks for.** `list_connections` returns each
connection's name, engine, database and default schema. It does not return
passwords, hosts or user names. Rows come back a page at a time (50 rows by
default, 500 at most). Pharos cuts long cells to 200 characters by default, and
a page stops early when it reaches about 100 KB.

**Variable values stay hidden unless you share them.** `list_variables` returns
each variable's name, type and scope. It returns values only if you turn on
**Let AI apps read query variable values**. With the setting off, a card that
uses `{{name}}` still runs with your value, and `get_card` shows the SQL that
ran, so an app can see a value after it uses one.

**Query history is shared in full.** `search_history` returns the SQL, timing,
row count and error message of past runs on every connection. Pharos cuts long
SQL to 2,000 characters by default. It does not return the rows of past runs.

**Pharos asks for passwords as usual.** If a connection needs a password, or
needs Touch ID, Pharos asks you in its window. The AI app never sees the
password.

To stop all access, turn off **Allow AI apps to use Pharos**. Pharos closes every
app's connection at once and removes the socket.

---

## The tools

| Tool | What it does |
|---|---|
| `list_connections` | Lists the saved connections: id, name, engine, database, default schema, and whether Pharos is connected. |
| `connect` | Connects to a saved connection and waits for the result. |
| `list_tabs` | Lists the open query tabs in every window, with the connection, the bound Session and the card count. |
| `list_saved_sessions` | Lists the saved Sessions in the library. You can filter by name or folder. |
| `list_workspaces` | Lists recent Results History workspaces, newest first. |
| `search_history` | Searches past runs, newest first, by words in their SQL (full-text), connection and status (`all`, `succeeded`, `failed`). Returns each run's SQL, time, duration, and row count or error. Pages with `offset` and `next_offset`. |
| `list_variables` | Lists the query variables, or those that a tab on one connection can use: name, type, global or linked. Values only if you allow it. |
| `open_session` | Opens a saved Session (with its saved results) or a workspace in a tab. Nothing runs. |
| `create_tab` | Opens a new, empty tab on a connection. |
| `list_cards` / `get_card` | Gives each card's id, name, version, lock, SQL, notes, and status: `never_run`, `queued`, `running`, `awaiting_confirmation`, `succeeded` or `failed`. Also gives the last run's row count or error. |
| `create_card` | Adds a card to a tab (`tab_id`), or to a new tab on a connection (`connection_id`). The card does not run. |
| `update_card` | Changes a card's SQL, name or notes. |
| `run_card` | Runs a card and waits for it, 30 seconds by default. Returns the status and the first rows. |
| `get_card_result` | Returns a page of a card's rows: columns with their types, then rows as text or `null`. Includes `next_offset`. |
| `cancel_card` | Removes a queued card from the queue, or cancels a running card on the server. |
| `save_session` | Saves the tab in place if it is bound to a Session or a `.sql` file. Otherwise, creates a new Session with the name you give. |

Cards from an AI app follow the same rules as your own cards (see
[Query Editor](query-editor.md)):

- After a card has run, a run of changed SQL keeps the old version, locks it,
  and puts the result on a new version below it. `run_card` returns the new
  card's id in that case.
- A locked version cannot change its SQL.
- `{{name}}` [query variables](query-variables.md) are filled in from your
  variables. A run with a missing variable is refused, and the reason is given
  to the app.
- Every card of a tab runs on the tab's own connection, one card at a time.

`get_card_result` pages through the rows that Pharos has loaded, up to the row
limit in **Settings ▸ Query**. If `server_has_more` is true, the database has
more rows. Ask the app to aggregate, or to add `LIMIT` and `OFFSET` to the
query.

{: .note }
To help an AI app write good card names and notes, give it the
[Query Format for AI Agents](ai-agent-query-format.md).

---

## Troubleshooting

| Symptom | What to check |
|---|---|
| Every tool call says that Pharos is not running, or that its MCP server is off | Open Pharos, and turn on **Settings ▸ Security & Privacy ▸ Allow AI apps to use Pharos**. |
| The caption says "The server could not start" | Another copy of Pharos with the same bundle identifier already has the socket. Quit the other copy. |
| `run_card` returns `awaiting_confirmation` | Pharos is waiting for you to answer the confirmation sheet in its window. |
| `run_card` says that the tab has no connection | Create the card with `connection_id`, or choose a connection for the tab in Pharos. |
| Claude does not list Pharos | Look at the `mcp-server-pharos.log` file in `~/Library/Logs/Claude`. Make sure that the `command` path goes to the `Pharos` file inside the app. |

To test the command by hand, run it in Terminal and paste one line. Pharos
answers with one line of JSON:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | /Applications/Pharos.app/Contents/MacOS/Pharos --mcp
```

---

## See also

- [Shortcuts and Spotlight](automation.md): the other way to automate Pharos
- [Query Execution](query-execution.md): the run queue and the destructive-query confirmation
- [Settings](settings.md#security--privacy-pane): the Security & Privacy pane
