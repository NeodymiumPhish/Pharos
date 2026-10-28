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

Open it with the **Variable Manager** button in the window toolbar (braces, at the right of the toolbar) or **Window > Variable Manager**. It is one window for the whole app. **Cmd+W** closes it.

The window has a Liquid Glass **sidebar** on the left and the selected variable's **form** on the right.

- **The sidebar** has one row for each variable: `{{name}}` in a monospaced font (**Untitled** while the name is empty), then the type and a short form of the value — "Number · 42", "Date · Today", "List · 12 items". A linked variable adds the number of its connections ("· 2 connections"). A variable whose value cannot render shows a warning symbol; rest the pointer on it to read the problem.
- **+** in the toolbar (**New Variable**) adds a variable and puts the caret in its name. The **Filter** field at the right of the toolbar narrows the sidebar to the rows whose name, type or value preview contains the text (case- and diacritic-insensitive). "No Matches" shows when nothing matches.
- Right-click a row for **Duplicate** and **Delete**. **Duplicate** adds a copy below the original, named `<name>_copy` (then `_copy2`, `_copy3`…). The **Delete** key, **Edit > Delete** and the **Delete Variable** button at the foot of the form also delete the selected variable. A delete is immediate.
- A new variable that you leave with an empty name and an empty value is removed when you select another row or close the window.

The form has three boxes:

- **Variable** — the **Name**, the **Type** pop-up, and for some types a second control: **With time zone** for a Timestamp, **Items are** (Text or Number) for a List.
- **Value** — the editor for the type (see [Types and Substitution](#types-and-substitution)), then **Renders as**: the SQL that the variable puts into the query, in a monospaced, selectable label. When the value cannot render, **Renders as** says why in red, for example "The value is not a valid number: "4x"." or "Nothing: the value is empty."
- **Connections** — where the variable applies: **All connections**, or **Only these connections** with a ticked list of your saved connections and the DuckDB files and in-memory databases that are open now. Until you tick one, the variable stays global. A linked connection that was removed shows as **Missing connection**; untick it to remove the link.

Edits apply as you make them: there is no Save button. The one exception is the name, which is applied when you move to another control or row, or close the window (see [Duplicate Names](#duplicate-names)).

In the editor, typing **`{{`** opens a list of the variables the tab can use, filtered as you type the name. Choosing a variable only writes `{{name}}`. When no variable has the name you typed, the last row creates one: choosing it writes the token **and** opens the new variable in the Variable Manager. Click a `{{name}}` token in the editor at any time to open that variable.

Because the list is shared, an edit in the Variable Manager appears at once in every window's editor highlighting.

### Change a variable in a tab

To use a different variable everywhere a tab uses one (for example `{{router}}` → `{{coda_dlink}}`):

1. Click the **Variables** pull-down (**{ }**) in the editor's header row. It shows when the tab's cards use a variable, and lists each one. **Undefined** marks a name that no variable has.
2. Choose the variable, then **Change To**, then the variable to use. The list holds the variables the tab's connection can use, each with what it renders as.

Under **Change To**, a grey line shows what the variable puts into the query when it runs: **Renders as** and the first line of the rendered SQL (up to 60 characters, then "…"). A list shows as `('a', 'b')` and a date as a `DATE` literal, as in the Variable Manager's **Renders as**. A warning sign marks a name that no variable has (**Undefined**), a value that renders nothing, and a value that cannot render (with the reason).

A right-click on a `{{name}}` token in a card gives the same list (**Change Variable To**).

The change writes every `{{name}}` in all the tab's cards, `{{ name }}` with spaces too, and not other names such as `{{name_2}}`. It is one step for **Edit > Undo** in the focused card. A locked version (one that holds results) keeps its SQL; a message says how many versions were not changed. **Show in Variable Manager** in the same submenu opens the variable.

## Types and Substitution

Choose the type from the **Type** pop-up: Literal, Text, Number, Bool, Date, Timestamp or List. When you run the query, each placeholder is replaced according to its variable's type:

| Type | Editor | Stored value → substitution |
|------|--------|-----------------------------|
| Literal | Text box | Inserted verbatim — for identifiers, expressions, or SQL fragments. `orders_2026` → `orders_2026` |
| Text | Text box | Single-quoted, with apostrophes doubled. `O'Brien` → `'O''Brien'` |
| Number | One-line field, checked as you type | Inserted bare. `42.5` → `42.5` |
| Bool | **True / False / NULL** segmented control | `true`, `false` or `NULL` |
| Date | **Fixed / Today**, then a date picker | `2026-10-28` → `DATE '2026-10-28'`; Today → `CURRENT_DATE` |
| Timestamp | **Fixed / Now**, then a date and time picker | `2026-10-28 14:30:00` → `TIMESTAMP '2026-10-28 14:30:00'`; Now → `LOCALTIMESTAMP` |
| Timestamp, **With time zone** on | **Fixed / Now**, a date and time picker, and a **Time zone** pop-up | `2026-10-28 14:30:00 America/New_York` → `TIMESTAMPTZ '2026-10-28 14:30:00-04:00'`; Now → `CURRENT_TIMESTAMP` |
| List, **Items are** Text | Text box, one item per line | Each item quoted, in parentheses. `a` and `b'c` → `('a', 'b''c')` |
| List, **Items are** Number | Text box, one item per line | Each item bare, in parentheses. `1`, `2.5`, `-3` → `(1, 2.5, -3)` |

Substitution happens at execution time — the editor text always keeps the `{{token}}` form — with the variables the tab's connection can use. A locked [query card](query-editor.md#versions) run again with different values counts as edited, so it makes a new version. It is also applied to **EXPLAIN**, when exporting a query as a SQL file, and when copying or sharing a saved Session's SQL (with the variables of the Session's own connection, or the global ones when it has none).

### Text and Literal

The text box starts one line high and grows with the value, up to 12 lines; after that it scrolls. A line-number gutter shows when the value has more than one line. Lines do not wrap: a long line scrolls sideways. A caption under the box gives the size of the value.

### Number

A Number is an optional sign and digits, with an optional decimal part (`42`, `-3`, `2.5`, `.5`). Exponents and non-ASCII digits are refused. Spaces and line breaks around the number are ignored. While the value is not a number, the field shows a red outline and a red caption gives the reason. Pharos keeps what you typed.

### Date and Timestamp

- **Fixed** shows a date picker that you can type into or step with the arrows. The calendar button beside it opens a popover with a calendar (and a clock for a Timestamp).
- **Today** (Date) and **Now** (Timestamp) store a relative value. It renders as a SQL keyword — `CURRENT_DATE`, `LOCALTIMESTAMP` or `CURRENT_TIMESTAMP` — so the database works out the date or time when the query runs, in the session's time zone.
- Switching from **Today** or **Now** back to **Fixed** starts from the current date and time on this Mac.

A Date is stored as `YYYY-MM-DD` and a Timestamp as `YYYY-MM-DD HH:MM:SS`. Neither has a time zone: the picker shows exactly the stored fields.

### Time zones

Turn on **With time zone** to make a Timestamp a `TIMESTAMPTZ`. The **Time zone** pop-up lists **UTC** and this Mac's time zone first, then every time zone that macOS knows. The value is stored with the zone's name, such as `2026-10-28 14:30:00 America/New_York`, and changing the zone keeps the wall-clock time.

When the query runs, the zone name becomes the numeric UTC offset that the zone has on that date and time (`-04:00` above, `-05:00` in January), so PostgreSQL and DuckDB both accept the literal. A time that does not exist in the zone, because the clocks skip it at the start of daylight saving time, is refused. A time that occurs twice, when the clocks go back, uses the earlier of the two.

### Lists

A List renders as a parenthesized list, so write the parentheses' place in the SQL without them:

```sql
SELECT * FROM hosts WHERE ip IN {{watch_list}};
```

Type one item per line. Blank lines are ignored, and spaces around each item are removed. A List of Text quotes each item; a List of Numbers checks each item as a Number. The caption under the box counts the items, and for a List of Numbers names the lines that are not numbers: "12 items · 1 not a number (line 4)". An empty list is refused, because `IN ()` is a syntax error.

When you paste more than one item into a List, Pharos splits the pasted text into lines, one item on each line:

- A **spreadsheet column** or any text with several lines gives one item for each line. When every line but the last ends in the same `,` or `;` (a SQL list pasted one item to a line), that separator is removed.
- A **single line** is split on tabs (a spreadsheet row); with no tab, on commas (a CSV row); with neither, on semicolons. A separator inside quotes does not split: `'a,b', 'c'` gives two items, `a,b` and `c`.
- One pair of brackets around the whole text is removed, so `('a', 'b')` and `[1, 2, 3]` work.
- One pair of matching quotes, `'…'` or `"…"`, is removed from each item, and a doubled quote inside (`''` or `""`) becomes one. An apostrophe inside a word, as in `O'Brien`, stays.
- Duplicates stay in the list.

Pasting a single item inserts it as typed, with its quotes removed, and adds no line breaks.

### Changing the type

A type change keeps as much of the value as it can. A change to a List splits the value as a paste does, and a change from a List keeps the one-item-per-line text. A change to Date or Timestamp reads the value as a date or date and time (`2026-10-28`, `2026/10/28`, ISO 8601 with `T`, `Z` or an offset). A value it cannot read becomes the current date and time as a fixed value. Today and Now carry over between Date and Timestamp. Date to Timestamp adds `00:00:00`, Timestamp to Date drops the time, and turning **With time zone** on adds this Mac's zone.

{: .warning }
**Caution — older Pharos builds.** The Date, Timestamp and List types are new. A Pharos build from before them reads a variable of one of these types as **Literal**, and inserts the stored value into the SQL as it is, without quotes: `2026-10-28` becomes the arithmetic `2026 - 10 - 28`, and a list becomes several lines of bare text. If you go back to an older build, check these variables before you run a query that uses them.

## Duplicate Names

Two variables can't share a name. If you type a name that another variable already has (an exact, case-sensitive match once both are trimmed of surrounding whitespace), the form refuses it: the name field turns red, the **Value** box is replaced by a red message ("A variable named "ops" already exists. Choose a different name."), and you can't move to another variable until you either pick a different name or delete the variable. Names are unique across the whole list, global and linked alike. Typing is never blocked, so you can type straight through a colliding name to a longer, unique one.

An empty name never collides, so adding several variables and naming them one at a time is unaffected.

{: .note }
If a duplicate pair does exist in the list (from an older build), the earlier of the two has no effect, since substitution always resolves a duplicate name to its last definition. Its form says so under the name: "Redefined below — this row has no effect."

## Validation

The Variable Manager checks every variable as you type, whether a query uses it or not. A value that cannot render shows a red **Renders as**, a warning symbol on its sidebar row, and, for a Number, a red outline and caption.

When you run a query, the same checks apply to the variables it uses. If any placeholder is undefined, or a value is invalid (a Number that is not a number, a Date that is not a real date, an empty List), the query does **not** run: an error toast lists the problems and the Variable Manager opens on the first one so you can fix it. A variable linked only to other connections says so: "{{env}} is linked to Prod and Staging, not to this tab's connection."

{: .tip }
Use the **Literal** type for anything that isn't a quoted value — table names, column lists, or whole SQL fragments. Use **Text** when you want proper string quoting handled for you, and **List** for an `IN` list.

## Persistence

The variable list is stored in Pharos's local database and restored, in order, at the next launch. Saving a Session (**Cmd+S**) keeps the placeholders intact and stores no values with it: a [saved Session](saved-queries.md) is rendered against whatever the app-wide list holds when you copy, share, export or run it. Removing a connection does not remove the variables linked to it. Tokens in a card's [notes](query-editor.md#notes) are never rendered: notes describe the query and are not part of what runs.
