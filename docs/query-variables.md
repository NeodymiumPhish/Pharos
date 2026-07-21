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

Click the **braces button** at the right end of the editor toolbar to toggle the **Variables** panel, docked to the right of the editor. Click **+** to add a variable; each row has:

- the **name** (matched against `{{name}}` tokens)
- the **value**
- a **type** — one of Literal, Text, Number, Bool, or Null

The panel is per-tab (each query tab has its own variables and panel visibility) and can be resized by dragging its divider.

## Types and Substitution

When you run the query, each placeholder is replaced according to its type:

| Type | Behavior | Example value → substitution |
|------|----------|------------------------------|
| Literal | Inserted verbatim — for identifiers, expressions, or SQL fragments | `orders_2026` → `orders_2026` |
| Text | Single-quoted, with apostrophes escaped | `O'Brien` → `'O''Brien'` |
| Number | Validated as numeric, inserted bare | `42.5` → `42.5` |
| Bool | Normalized (`true/t/1/yes/y`, `false/f/0/no/n`) | `yes` → `true` |
| Null | Emits `NULL` (the value field is ignored) | → `NULL` |

Substitution happens at execution time — the editor text always keeps the `{{token}}` form. It is also applied when exporting a query as a SQL file and when copying a saved query's SQL.

## Validation

If any placeholder is undefined, or a typed value is invalid (e.g., a non-numeric Number), the query does **not** run: an error toast lists the problems and the Variables panel opens automatically so you can fix them.

{: .tip }
Use the **Literal** type for anything that isn't a quoted value — table names, column lists, or whole SQL fragments. Use **Text** when you want proper string quoting handled for you.

## Persistence

Variables are stored with the tab's saved query, so reopening a saved query restores its variables and their last values. Saving (**Cmd+S**) keeps the placeholders intact; only exports render them.
