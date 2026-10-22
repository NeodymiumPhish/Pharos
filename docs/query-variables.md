---
layout: default
title: Query Variables
nav_order: 6
---

# Query Variables
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

Query variables let you parameterize SQL with `{{name}}` placeholders and fill in values in the **Variable Manager** — change the value and re-run instead of editing the query text. There is **one list of variables for the whole app**. A variable is **global** (every connection, the default) or **linked to some connections**: a tab can use the global variables and those linked to its connection. A value you enter once (a target IP, a date range, a row limit) is available to every query that can use it, in every window, until you change it. The list is saved locally and comes back on the next launch.

## Syntax

Write a placeholder anywhere in your SQL using double curly braces:

```sql
SELECT * FROM events
WHERE created_at >= {{start_date}}
  AND ip_address = {{ip}}
LIMIT {{max_rows}};
```

Variable names are identifiers (letters, digits and underscores, with at least one letter or underscore), and whitespace inside the braces is tolerated (`{{ name }}`). In the editor, variables the tab can use are highlighted indigo; undefined ones, and ones linked only to other connections, are red.

## The Variable Manager

Open it with the **Variable Manager** button in the window toolbar (braces, at the right of the toolbar) or **Window > Variable Manager**. It is one window for the whole app.

- The **list** on the left shows every variable: `{{name}}`, its type, a preview of its value, and where it applies (**All connections** or **2 connection(s)**). The **Filter** field above it narrows the list to rows whose name **or value** contains the text (case-insensitive). **+** adds a variable with its name field focused. Right-click a row for **Delete**.
- The **detail** on the right edits the selected variable: the name, a **type** popup, and the value, in a multi-line editor with its own line-number gutter — useful for a comma- or newline-separated list of IDs.
- **Connections**, below the value, sets where the variable applies: **All connections**, or **Only these connections** with a ticked list of your saved connections and the DuckDB files and in-memory databases that are open now. Until you tick one, the variable stays global. A linked connection that was removed shows as **Missing connection**; untick it to remove the link.

In the editor, typing **`{{`** opens a list of the variables the tab can use, filtered as you type the name. Choosing a variable only writes `{{name}}`. When no variable has the name you typed, the last row creates one: choosing it writes the token **and** opens the new variable in the Variable Manager with its value field focused. Click a `{{name}}` token in the editor at any time to open that variable.

Because the list is shared, an edit in the Variable Manager appears at once in every window's editor highlighting.

## Types and Substitution

Four types, chosen from the detail level's type popup. When you run the query, each placeholder is replaced according to its variable's type:

| Type | Behavior | Example value → substitution |
|------|----------|------------------------------|
| Literal | Inserted verbatim — for identifiers, expressions, or SQL fragments | `orders_2026` → `orders_2026` |
| Text | Single-quoted, with apostrophes escaped | `O'Brien` → `'O''Brien'` |
| Number | Validated as numeric, inserted bare | `42.5` → `42.5` |
| Bool | One of three values — `True`, `False`, or `NULL`, chosen from a segmented control rather than typed — normalized to lowercase `true`/`false` or the SQL keyword `NULL` | `False` → `false` |

Substitution happens at execution time — the editor text always keeps the `{{token}}` form — with the variables the tab's connection can use. A locked [query card](query-editor.md#versions) run again with different values counts as edited, so it makes a new version. It is also applied to **EXPLAIN**, when exporting a query as a SQL file, and when copying or sharing a saved Session's SQL (with the variables of the Session's own connection, or the global ones when it has none).

## Duplicate Names

Two variables can't share a name. If you type a name that another variable already has (an exact, case-sensitive match once both are trimmed of surrounding whitespace), the detail refuses it: the name field and an inline message turn red, and you can't move to another variable until you either pick a different name or delete the variable. Names are unique across the whole list, global and linked alike. Typing is never blocked, so you can type straight through a colliding name to a longer, unique one.

An empty name never collides, so adding several variables and naming them one at a time is unaffected.

{: .note }
If a duplicate pair does exist in the list, the earlier of the two rows is shown dimmed ("not used — redefined below") and inert in the detail level, since substitution always resolves a duplicate name to its last definition. A filter that hides the later twin does not change this: the visible row stays dimmed.

## Validation

If any placeholder is undefined, or a typed value is invalid (e.g., a non-numeric Number), the query does **not** run: an error toast lists the problems and the Variable Manager opens on the first one so you can fix it. A variable linked only to other connections says so: "{{env}} is linked to Prod and Staging, not to this tab's connection."

{: .tip }
Use the **Literal** type for anything that isn't a quoted value — table names, column lists, or whole SQL fragments. Use **Text** when you want proper string quoting handled for you.

## Persistence

The variable list is stored in Pharos's local database and restored, in order, at the next launch. Saving a Session (**Cmd+S**) keeps the placeholders intact and stores no values with it: a [saved Session](saved-queries.md) is rendered against whatever the app-wide list holds when you copy, share, export or run it. Removing a connection does not remove the variables linked to it. Tokens in a card's [notes](query-editor.md#notes) are never rendered: notes describe the query and are not part of what runs.
