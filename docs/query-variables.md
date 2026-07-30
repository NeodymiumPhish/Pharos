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

Query variables let you parameterize SQL with `{{name}}` placeholders and fill in values from a panel beside the editor — change the value and re-run instead of editing the query text. Variables are saved along with [saved queries](saved-queries.md), so a parameterized query stays reusable.

## Syntax

Write a placeholder anywhere in your SQL using double curly braces:

```sql
SELECT * FROM events
WHERE created_at >= {{start_date}}
  AND ip_address = {{ip}}
LIMIT {{max_rows}};
```

Variable names are identifiers (letters, digits, underscores; not starting with a digit), and whitespace inside the braces is tolerated (`{{ name }}`). In the editor, defined variables are highlighted indigo and undefined ones red.

## The Variables Panel

Click the **braces button** at the right end of the editor toolbar to toggle the **Variables** panel, docked to the right of the editor. It's open by default for a new tab.

The panel is a two-level list and detail, similar to Settings on iOS:

- The **list** shows every variable as a read-only row: `{{name}}`, its type, and a preview of its value. A row with a value that would break the query (e.g., an empty Literal, or an invalid Number/Bool) shows a warning badge. Click **+** to add a variable, or a row to drill in and edit it. Right-click a row for a **Delete** option that doesn't require drilling in.
- The **detail** level, reached by clicking a row, is where you actually edit: the name, a **type** popup, and the value. Editing the value happens in a multi-line editor with its own line-number gutter, matching the SQL editor — useful for a comma- or newline-separated list of IDs. A **Back** chevron (or Escape) returns to the list.

The panel is per-tab (each query tab has its own variables and panel visibility) and can be resized by dragging its divider.

## Types and Substitution

Four types, chosen from the detail level's type popup. When you run the query, each placeholder is replaced according to its variable's type:

| Type | Behavior | Example value → substitution |
|------|----------|------------------------------|
| Literal | Inserted verbatim — for identifiers, expressions, or SQL fragments | `orders_2026` → `orders_2026` |
| Text | Single-quoted, with apostrophes escaped | `O'Brien` → `'O''Brien'` |
| Number | Validated as numeric, inserted bare | `42.5` → `42.5` |
| Bool | One of three values — `True`, `False`, or `NULL`, chosen from a segmented control rather than typed — normalized to lowercase `true`/`false` or the SQL keyword `NULL` | `False` → `false` |

Substitution happens at execution time — the editor text always keeps the `{{token}}` form. It is also applied when exporting a query as a SQL file and when copying a saved query's SQL.

## Duplicate Names

Two variables can't share a name. If you type a name that another variable already has (an exact, case-sensitive match once both are trimmed of surrounding whitespace), the detail level refuses it: the name field and an inline message turn red, and you can't leave the screen — by Back, Escape, or otherwise — until you either pick a different name or delete the variable. Typing is never blocked, so you can type straight through a colliding name to a longer, unique one.

An empty name never collides, so adding several variables and naming them one at a time is unaffected.

{: .note }
A duplicate pair can still arrive from a saved query created before this rule existed. In that case the earlier of the two rows is shown dimmed in the list ("not used — redefined below") and inert in the detail level, since `render` always resolves a duplicate name to its last definition — but you still have to rename it to leave its detail level, since the rule applies to every edit going forward.

## Validation

If any placeholder is undefined, or a typed value is invalid (e.g., a non-numeric Number), the query does **not** run: an error toast lists the problems and the Variables panel opens automatically so you can fix them.

{: .tip }
Use the **Literal** type for anything that isn't a quoted value — table names, column lists, or whole SQL fragments. Use **Text** when you want proper string quoting handled for you.

## Persistence

Variables are stored with the tab's saved query, so reopening a saved query restores its variables and their last values. Saving (**Cmd+S**) keeps the placeholders intact; only exports render them.
