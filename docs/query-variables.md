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

Query variables let you parameterize SQL with `{{name}}` placeholders and fill in values from the sidebar — change the value and re-run instead of editing the query text. There is **one list of variables for the whole app**: every window, every tab and every connection resolves its placeholders against the same list, so a value you enter once (a target IP, a date range, a row limit) is available to every query you run, on any database, until you change it. The list is saved locally and comes back on the next launch.

## Syntax

Write a placeholder anywhere in your SQL using double curly braces:

```sql
SELECT * FROM events
WHERE created_at >= {{start_date}}
  AND ip_address = {{ip}}
LIMIT {{max_rows}};
```

Variable names are identifiers (letters, digits, underscores; not starting with a digit), and whitespace inside the braces is tolerated (`{{ name }}`). In the editor, defined variables are highlighted indigo and undefined ones red.

## The Variables Navigator

Variables live in the sidebar, as the **Variables** navigator — the second icon (braces) of the grouped navigator selector in the window toolbar, between Query Library and Results History; **View > Navigators > Variables**, **Cmd+Opt+2**. Pressing the icon that is already selected hides the sidebar; pressing it again brings it back.

The navigator is a two-level list and detail, similar to Settings on iOS:

- The **list** shows every variable as a read-only row: `{{name}}`, its type, and a preview of its value. A row with a value that would break the query (e.g., an empty Literal, or an invalid Number/Bool) shows a warning badge — but only when the active editor tab actually references that name; an unreferenced variable is never flagged. Click a row to drill in and edit it. Right-click a row for a **Delete** option that doesn't require drilling in.
- The **detail** level, reached by clicking a row, is where you actually edit: the name, a **type** popup, and the value. Editing the value happens in a multi-line editor with its own line-number gutter, matching the SQL editor — useful for a comma- or newline-separated list of IDs. A **Back** chevron (or Escape) returns to the list.

To add a variable, open the **+** pull-down beside the sidebar's filter field and choose **New Variable**; the new row opens at the detail level with its name field focused. The **Filter** field along the bottom of the sidebar narrows the list to rows whose name **or value** contains the text (case-insensitive), so you can find a variable by the value you remember typing into it.

Because the list is shared, an edit made in one window appears at once in every other window's sidebar, and every editor's highlighting follows it.

## Types and Substitution

Four types, chosen from the detail level's type popup. When you run the query, each placeholder is replaced according to its variable's type:

| Type | Behavior | Example value → substitution |
|------|----------|------------------------------|
| Literal | Inserted verbatim — for identifiers, expressions, or SQL fragments | `orders_2026` → `orders_2026` |
| Text | Single-quoted, with apostrophes escaped | `O'Brien` → `'O''Brien'` |
| Number | Validated as numeric, inserted bare | `42.5` → `42.5` |
| Bool | One of three values — `True`, `False`, or `NULL`, chosen from a segmented control rather than typed — normalized to lowercase `true`/`false` or the SQL keyword `NULL` | `False` → `false` |

Substitution happens at execution time — the editor text always keeps the `{{token}}` form. It is also applied to **EXPLAIN**, when exporting a query as a SQL file, and when copying or sharing a saved query's SQL.

## Duplicate Names

Two variables can't share a name. If you type a name that another variable already has (an exact, case-sensitive match once both are trimmed of surrounding whitespace), the detail level refuses it: the name field and an inline message turn red, and you can't leave the screen — by Back, Escape, or otherwise — until you either pick a different name or delete the variable. Typing is never blocked, so you can type straight through a colliding name to a longer, unique one.

An empty name never collides, so adding several variables and naming them one at a time is unaffected.

{: .note }
If a duplicate pair does exist in the list, the earlier of the two rows is shown dimmed ("not used — redefined below") and inert in the detail level, since substitution always resolves a duplicate name to its last definition. A filter that hides the later twin does not change this: the visible row stays dimmed.

## Validation

If any placeholder is undefined, or a typed value is invalid (e.g., a non-numeric Number), the query does **not** run: an error toast lists the problems and the sidebar opens on the Variables navigator so you can fix them.

{: .tip }
Use the **Literal** type for anything that isn't a quoted value — table names, column lists, or whole SQL fragments. Use **Text** when you want proper string quoting handled for you.

## Persistence

The variable list is stored in Pharos's local database and restored, in order, at the next launch. Saving a query (**Cmd+S**) keeps the placeholders intact and stores no values with it: a [saved query](saved-queries.md) is rendered against whatever the app-wide list holds when you copy, share, export or run it.
