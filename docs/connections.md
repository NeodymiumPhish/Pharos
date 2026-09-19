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

- **Left** — the list of saved connections. Each row shows a status dot (green = connected, yellow = connecting, red = error, gray = disconnected), the connection name, and `host:port · database`, followed by `· via <bastion>` when the connection uses an SSH tunnel. Drag rows to reorder. Use **+** to add a connection and **−** to delete the selected one.
- **Right** — the detail form for the selected connection.

| Field | Description | Default |
|-------|-------------|---------|
| Name | A display label for this connection | — |
| Host | Server hostname or IP address | — |
| Port | PostgreSQL listening port | 5432 |
| Database | Database name to connect to | postgres |
| Username | PostgreSQL role for authentication | — |
| Password | Password for the role (stored in the Keychain) | — |
| SSL Mode | Prefer, Require, Verify CA, Verify Full, or Disable — see [SSL Modes](#ssl-modes) | Prefer |
| Root Certificate | The PEM root certificate that **Verify CA** and **Verify Full** check the server against. Shown only for those two modes; empty uses the system trust store | Empty |
| Default Schema | Schema focused on connect. Filled from the open connection when the connection is already connected and its settings are unchanged; otherwise press **Test Connection** first | None |
| Connect through an SSH tunnel | Reach the database through a bastion — see [SSH Tunnels](#ssh-tunnels) | Off |
| Read-only connection | See [Read-only connections](#read-only-connections) | Off |
| Time Zone | The `TimeZone` this connection's sessions ask for. **Use the Settings default** falls back to Settings ▸ Connections ▸ Time zone, and then to the server's own | Use the Settings default |

The **Session** rows at the foot of the form — read-only, connect at launch and
the time zone — apply to connections opened after the change, because a
connection's session values are set when its pool is built.

App-wide connection settings — the default port for a new connection, the pool
size, the connect timeout, keepalives — are in
[Settings ▸ Connections](settings.md#connections-pane).

## SSL Modes

| Mode | What it does |
|------|--------------|
| Prefer | Tries TLS, then falls back to an unencrypted connection if TLS does not complete. This is the default, and what libpq's own `prefer` means. |
| Require | Insists on TLS, but does not check the server's certificate. |
| Verify CA | Insists on TLS and checks that a trusted certificate authority signed the server's certificate. |
| Verify Full | Verify CA, and also checks that the certificate's host name matches the host you connected to. |
| Disable | No TLS at all. |

**Verify CA** and **Verify Full** read the **Root Certificate** field. Leave it
empty to use the system trust store; point it at a PEM file to trust a private
CA. A certificate the server does not match fails the connect with the
server's own message. Only **Prefer** ever falls back to an unencrypted
connection.

## Read-only connections

Tick **Read-only connection** to open every session for that connection with
`default_transaction_read_only` on. The **server** then refuses every write —
`INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `CREATE`, `DROP` — with SQLSTATE
25006, and Pharos shows **"This connection is read-only."** in front of the
server's own message.

The buttons that write — **Import CSV…**, **Clone Table…** and the results
grid's inline editing — are refused before they start, with the same sentence,
so nothing is half-done before the refusal arrives.

Two things this is not:

- It is **not** a permission. A read-only connection is a client-side session
  setting, and anything else on your Mac can still connect to that server as
  that role and write. For a real guarantee, use a PostgreSQL role that has no
  write privileges.
- It does **not** stop a read that is expensive. It stops writes, nothing else.

Like the other session rows, it applies the next time the connection opens.

Edits are made inline — click **Save** to persist, or **Revert** to discard. Unsaved new connections are marked "Not saved" until saved.

## Connecting at launch

**Connect when Pharos starts** opens this connection as the app starts, after the saved tabs are back. A connection the restored session has already opened is left alone rather than opened twice.

A connection that asks for Touch ID is opened **last, and one at a time**. Several system authentication prompts raised together stack on one another, and there is nothing on a prompt to say which connection it belongs to. Connections that ask for nothing all go at once, since there is nothing to queue behind.

Nothing here holds up the launch: a connection that never answers leaves its own row spinning, and after a minute it stops holding the queue behind it.


## Testing a Connection

Click **Test Connection** to verify the settings:

- **Success** — shows "Connected" with the round-trip latency in milliseconds, and populates the **Default Schema** menu with the database's schemas. Pick one and press **Save**; choose **None** at the top of the menu to clear the default. The fetched list stays on screen for the rest of the session, so you do not have to test again after editing another connection.

**Test Connection is only needed when Pharos cannot already answer.** If the connection is connected and you have not changed its host, port, database, username, SSL mode or Touch ID setting, the **Default Schema** menu fills itself from the open connection as soon as you select the record. Editing any of those fields takes the menu back to "Test connection first", because the open connection no longer describes what the form says.
- **Failure** — shows the PostgreSQL error message in red

**Test Connection opens the tunnel too.** A connection with an SSH tunnel takes the same path as Connect, so the button cannot pass settings that Connect would refuse. A tunnel failure is reported in place of the PostgreSQL error.

## SSH Tunnels

A connection can reach its PostgreSQL server through an SSH tunnel, for a database that is only reachable from a bastion host. Tick **Connect through an SSH tunnel** in the **SSH Tunnel** section of the connection's form.

Pharos runs the system `ssh` (`/usr/bin/ssh`) as a child process:

```
ssh -N -L 127.0.0.1:<local port>:<database host>:<database port> <user>@<ssh host>
```

The tunnel opens before the connection pool and closes when you disconnect, when you delete the connection, or when you quit Pharos. The local port is chosen for you and is bound to the loopback address only, so the tunnel is never reachable from the network. **Host** and **Port** in the form stay the DATABASE's — they are what the SSH server connects on your behalf to, not what Pharos connects to.

### Fields

| Field | Description | Default |
|-------|-------------|---------|
| SSH Host | The bastion, or a `Host` alias from `~/.ssh/config` | — |
| SSH Port | The SSH server's port | 22 |
| SSH User | Leave empty to let `~/.ssh/config` choose | — |
| Authentication | SSH agent, Private key file, or Password | SSH agent |
| Key File | The private key, for **Private key file** | — |
| Passphrase / Password | The key's passphrase, or the SSH password | — |
| Accept new host keys | See **Host keys** below | Off |

### `~/.ssh/config` applies

Because Pharos runs the system `ssh`, your own configuration is used with no extra setting in Pharos: `Host` aliases, `ProxyJump`, `IdentityFile`, `IdentityAgent`, `Port` and `User` all work. Put an alias in **SSH Host** and Pharos will resolve it the way your terminal does.

This is how a 1Password SSH key works. 1Password sets `IdentityAgent` in `~/.ssh/config`, and the tunnel signs with it — 1Password may ask you to approve the key the first time. Leave **Authentication** on **SSH agent**.

{: .note }
A GUI app inherits `SSH_AUTH_SOCK` from launchd, not from your shell. An agent started only in a shell startup file is invisible to Pharos. `IdentityAgent` in `~/.ssh/config` — the 1Password way — always works.

### Authentication modes

- **SSH agent** — the default and the safest. Pharos stores no SSH secret at all and `ssh` runs in batch mode, so it can never stop waiting for a prompt.
- **Private key file** — choose the key with **Choose…**. Leave **Passphrase** empty for a key with no passphrase; `ssh` is then given only this key, so a crowded agent cannot use up the server's attempts before yours is tried.
- **Password** — the SSH password for the account. Pharos answers the prompt for `ssh` through a helper it writes at startup. In this mode public key authentication is turned OFF, so a wrong password fails instead of silently succeeding with an agent key.

{: .warning }
In **Password** mode, and for a key with a passphrase, the secret is placed in the `ssh` process's environment for as long as the tunnel is open. Anyone logged in as you on this Mac can read it with `ps -E`. Use **SSH agent** or an unencrypted key file where you can.

### Host keys

Pharos never weakens host key checking. By default the SSH server's key must already be in your `~/.ssh/known_hosts`; an unknown key fails with:

> Pharos does not accept new host keys for this connection. Turn on Accept new host keys, or connect once from Terminal: ssh user@host

Two ways forward:

- Connect once from Terminal with the command in the message and answer the prompt yourself. This is the safest route, because you see the fingerprint.
- Tick **Accept new host keys** on this connection. The first connection then records an **unknown** key. A **changed** key still fails, so this never weakens a key that is already known.

### Messages

| What you see | What it means |
|---|---|
| SSH authentication failed for `user@host`. | The SSH server refused your key or password. |
| SSH host `host` not found. | The SSH host name does not resolve on this Mac. |
| SSH host `host:port` did not answer. | Nothing is listening, or the connection timed out. |
| The SSH server could not reach `dbhost:dbport`. | The tunnel opened, but the bastion cannot reach the database. Check the database host and port, and that the bastion can resolve the name. |
| SSH tunnel closed: `reason` | The tunnel stopped during the session. Connect again. |

### Limits

- Two connections through the same bastion start two `ssh` processes.
- Pharos always runs `/usr/bin/ssh`. A Homebrew `ssh` is not used.
- A dead tunnel is noticed at the next query or metadata request, not the moment it dies.

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

Once connected, the [Schema Browser](schema-browser.md) populates and queries in that tab run against the selected connection. The **schema pull-down** beside the connection in the window toolbar shows the tab's schema (or **All Schemas**) and opens a searchable list to change it or to **Set as Default** for the connection.

## Remembering the password

Under **Authentication**, **Remember the password in the keychain** decides where this connection's password lives.

**On** (the default) the password is written to your login keychain and the connection opens without asking.

**Off**, three things happen:

- The password is **not** written to the keychain.
- The one already in your keychain for this connection is **deleted** when you save. Clearing the box is a destructive save, not merely a stop: a switch that left the old password behind would say the opposite of what it does.
- Pharos asks you for the password the first time you connect after each launch, in a small sheet showing the connection's name and address. What you type is kept **in memory only**, for as long as Pharos runs, so the rest of that session connects without asking again.

The sheet has a **Remember in the Keychain** box of its own. Ticking it turns this connection's setting back on and writes what you typed, so you can change your mind without opening the Connections Manager.

**Settings ▸ Security & Privacy ▸ Passwords** has one switch for this: **Forget typed passwords when this Mac sleeps**. It is off by default. Turned on, the passwords held in memory are dropped when the Mac goes to sleep, and you are asked again on waking. It never touches the keychain, so connections that remember their password are unaffected.

{: .note }
The **SSH tunnel**'s passphrase or password does **not** follow this switch. It is a different secret, with a switch of its own — see below.

## Remembering the SSH tunnel secret

Under **SSH Tunnel**, directly below the passphrase or password field, **Remember the SSH secret in the keychain** decides where the *tunnel's* secret lives. It is the same rule as the password's switch, applied to the other secret:

**On** (the default) the passphrase or password is written to your login keychain and the tunnel opens without asking.

**Off**, three things happen:

- The secret is **not** written to the keychain.
- The one already in your keychain for this tunnel is **deleted** when you save, exactly as clearing the password switch deletes the password.
- Pharos asks you for it the first time the bastion refuses the connection after each launch. What you type is kept **in memory only**, for as long as Pharos runs, and the whole connection — tunnel and database both — is retried with it.

The sheet names the **SSH host**, not the database, so you can tell it apart from the password sheet if both appear in one session. It calls the secret a *passphrase* for key-file authentication and a *password* for password authentication, matching the field in the form. It has a **Remember in the Keychain** box of its own, which turns the tunnel's setting back on and writes what you typed.

The row is hidden when the tunnel's authentication is **SSH agent**: the agent holds its own keys and Pharos never has a secret to keep. It is also asked for again after a wrong secret, not only a missing one — a bastion answers both the same way, and both are fixed by typing it again.

{: .important }
The two switches are **independent**. Turning off **Remember the password in the keychain** leaves the tunnel secret alone, and turning off **Remember the SSH secret in the keychain** leaves the database password alone. To keep nothing of a connection in your keychain, clear both.

**Settings ▸ Security & Privacy ▸ Passwords ▸ Forget typed passwords when this Mac sleeps** covers both kinds of typed secret. On sleep, a tunnel secret held in memory is dropped with the passwords, and you are asked for it again on waking.

## Touch ID

Each connection can carry its own gate. In the Connections Manager, under **Authentication**, tick **Require Touch ID to connect and to show the password**. Two things then ask you to authenticate first — with Touch ID, an unlocked Apple Watch, or your login password, whichever your Mac offers:

- **Connecting** with that connection, however the connection is started — the toolbar pull-down, **File > Connect**, or selecting the connection for a tab
- **Showing its stored password** in the form
- **Being asked for a password or an SSH tunnel secret**, before either sheet appears — the sheet must never become a way past the gate

One proof covers a whole piece of work: the gate, the sheet you type into, and the reconnect behind it do not each raise a prompt.

A gated connection shows `••••••••` in its password field instead of the stored password, and the field cannot be edited. Press **Show** beside it to authenticate; the real password then appears and the field becomes editable until you select another connection. Cancel the prompt and nothing changes — a caption under the field says so, and the password stays hidden. Saving the form while the password is hidden leaves the stored password exactly as it was.

If you cancel the prompt when connecting, the tab simply stays disconnected. Nothing failed, so no error is reported.

{: .note }
The gate guards the two places Pharos *acts* on the password. It does not change where the password is kept: the Keychain item is written and read exactly as before, so anything else on your Mac that could already read it still can. Think of it as a barrier against someone walking up to an unlocked Mac, not as extra protection for the stored password.

## Connection Storage

Connection metadata (name, host, port, database, username, SSL mode, root certificate path, default schema, Touch ID requirement, SSH tunnel settings, read-only, remember-password, connect-at-launch and the session time zone) is stored in a local SQLite database in Pharos's Application Support directory. Passwords are stored in the macOS Keychain, never in SQLite.

A connection with an SSH tunnel has up to **two** Keychain entries: the database password, and the SSH passphrase or password. Each is written only if its own remember switch is on, and deleting the connection removes both. The SSH tunnel's own settings — host, port, user, authentication mode, key path and the remember switch — are stored in SQLite with the secret removed, so the Keychain is the only place either secret lives.

{: .note }
Passwords never leave your machine — they live in the macOS Keychain and are read into memory only to open connections.

## Multiple Connections

You can save as many connections as needed, and because the active connection is per editor tab, you can work against several databases side by side — each tab's queries, schema browser view, and results follow that tab's connection.
