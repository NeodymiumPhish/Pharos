---
layout: default
title: Connections
nav_order: 3
---

# Connections
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

Connections are managed in the **Connections Manager** sheet (**Cmd+Shift+N** or **File > Manage Connections…**; **Done** or Escape closes it, and it asks before discarding unsaved edits) and selected **per editor tab** from the connection pull-down in the window toolbar. Different tabs can point at different databases at the same time.

## The Connections Manager

The Connections Manager is a two-pane window:

- **Left** — the list of saved connections. Each row shows a status dot (green = connected, yellow = connecting, red = error, gray = disconnected), the connection name, and `host:port · database`. Drag rows to reorder. Use **+** to add a connection and **−** to delete the selected one.
- **Right** — the detail form for the selected connection.

| Field | Description | Default |
|-------|-------------|---------|
| Name | A display label for this connection | — |
| Host | Server hostname or IP address | — |
| Port | PostgreSQL listening port | 5432 |
| Database | Database name to connect to | postgres |
| Username | PostgreSQL role for authentication | — |
| Password | Password for the role (stored in the Keychain) | — |
| SSL Mode | Prefer, Require, or Disable | Prefer |
| Default Schema | Schema focused on connect; populated after a successful Test Connection | None |

Edits are made inline — click **Save** to persist, or **Revert** to discard. Unsaved new connections are marked "Not saved" until saved.

## Testing a Connection

Click **Test Connection** to verify the settings:

- **Success** — shows "Connected" with the round-trip latency in milliseconds, and populates the **Default Schema** menu with the database's schemas. Pick one and press **Save**; choose **None** at the top of the menu to clear the default. The fetched list stays on screen for the rest of the session, so you do not have to test again after editing another connection.
- **Failure** — shows the PostgreSQL error message in red

## Connection Links

Pharos opens `postgres://` and `postgresql://` links — the standard PostgreSQL connection URI, as used by `psql`, hosting dashboards and CI settings pages. Open one from a browser, a terminal (`open "postgresql://…"`), or any app that makes links clickable, and the Connections Manager comes forward with a **new, unsaved** connection filled in from it.

Pharos reads the host, port, user, password, database name and the `sslmode` parameter:

```
postgresql://user:password@host:5432/dbname?sslmode=require
```

- Every part is optional. A missing port means 5432, and a missing host means `localhost`.
- The link may instead carry its parts as query parameters — `postgresql:///dbname?host=/tmp&user=me` — which is what libpq accepts. Where both are given, the part in the address wins.
- `sslmode` is mapped onto Pharos's three modes: `disable` → Disable, `allow` and `prefer` → Prefer, `require`, `verify-ca` and `verify-full` → Require. Anything else is ignored and the default stands.
- A list of hosts (`host1,host2`) uses the first one. Other parameters are ignored.
- The new connection is named `user@host/database`. Change it, or any other field, before saving.

{: .note }
A password in a link is put in the form only — the form shows "Password taken from the link." under the field. **Nothing is written to SQLite or the Keychain until you press Save**, so a link you did not want to keep is discarded by selecting another connection or pressing Revert.

A link Pharos cannot read shows an alert with the link in it, and changes nothing.

## Connecting and Disconnecting

In the window toolbar, open the **connection pull-down**. It lists every saved connection with a live status glyph and a checkmark on the tab's active connection, followed by **Connect**, **Disconnect** and **Refresh Metadata** (also in the **File** menu; Refresh Metadata is **Cmd+Shift+R**), then:

- **Connect** / **Disconnect** — open or close the connection for this tab
- **Refresh Connection** — reload schema metadata (refreshes the schema browser)
- **Manage Connections…** — open the Connections Manager

Once connected, the [Schema Browser](schema-browser.md) populates and queries in that tab run against the selected connection.

## Touch ID

Each connection can carry its own gate. In the Connections Manager, under **Authentication**, tick **Require Touch ID to connect and to show the password**. Two things then ask you to authenticate first — with Touch ID, an unlocked Apple Watch, or your login password, whichever your Mac offers:

- **Connecting** with that connection, however the connection is started — the toolbar pull-down, **File > Connect**, or selecting the connection for a tab
- **Showing its stored password** in the form

A gated connection shows `••••••••` in its password field instead of the stored password, and the field cannot be edited. Press **Show** beside it to authenticate; the real password then appears and the field becomes editable until you select another connection. Cancel the prompt and nothing changes — a caption under the field says so, and the password stays hidden. Saving the form while the password is hidden leaves the stored password exactly as it was.

If you cancel the prompt when connecting, the tab simply stays disconnected. Nothing failed, so no error is reported.

{: .note }
The gate guards the two places Pharos *acts* on the password. It does not change where the password is kept: the Keychain item is written and read exactly as before, so anything else on your Mac that could already read it still can. Think of it as a barrier against someone walking up to an unlocked Mac, not as extra protection for the stored password.

## Connection Storage

Connection metadata (name, host, port, database, username, SSL mode, default schema, Touch ID requirement) is stored in a local SQLite database in Pharos's Application Support directory. Passwords are stored in the macOS Keychain, never in SQLite.

{: .note }
Passwords never leave your machine — they live in the macOS Keychain and are read into memory only to open connections.

## Multiple Connections

You can save as many connections as needed, and because the active connection is per editor tab, you can work against several databases side by side — each tab's queries, schema browser view, and results follow that tab's connection.
