---
layout: default
title: Tags
nav_order: 21
---

# Tags
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

A **tag** marks the result rows whose values match its **rules**: an address you are tracking, a CIDR range, a customer id, a date range. Every result grid in every tab shows the rows a tag matches, with a coloured bar at the row's leading edge and a tint on the matched cells. Tags are app-wide: they belong to no connection, so one tag finds its values in any database.

A tag has a **name**, a **colour**, an optional **note**, and any number of rules.

## Rules and conditions

A rule is one or more **conditions**. A row matches a rule when every condition is satisfied by some cell in the row — not necessarily the same cell. A tag matches a row when any of its rules does.

A condition has a **type** and an **operator**, and it is compared only with cells of a column of the same type, in any column of the result:

| Type | Operators |
|---|---|
| Text | is, matches (a pattern with `*` and `?`) |
| Address | is, in range (a CIDR range such as `10.0.0.0/8`) |
| Number | is, >, ≥, <, ≤, between |
| Date & time | is, after, on or after, before, on or before, between |
| UUID | is |

Text compares without regard to case. A CIDR range also matches addresses held in text columns.

In the grid, a row that fully satisfies a rule shows a solid bar; a row that satisfies only some conditions of a rule shows a dashed one.

## The Tag Manager

Open it with the **Tag Manager** button in the window toolbar (the tag, at the right of the toolbar), **Window > Tag Manager**, **Edit > Manage Tags…**, **Manage Tags…** in a result grid's right-click menu, or the **Edit** button beside a tag in the [Inspector](inspector.md). It is one window for the whole app, and it opens even when there are no tags yet and no results on screen.

- The list on the left shows every tag. **New Tag** adds one; the trash button deletes the selected tag.
- On the right: the tag's name, colour and note, then its rules. **Add Rule** adds a rule with one empty condition; pick its type and operator and type the value. **Add Condition** adds another condition to a rule.
- When results are loaded in the front tab, the manager counts the loaded rows the tag matches.
- **Save** writes your changes and keeps the window open. **Cancel** closes it without saving. Closing the window with unsaved changes asks first.

### Add Values…

**Add Values…**, beside **Add Rule**, makes many rules at once: paste or type values, one per line, and each line becomes a rule with one condition. The type is detected from the value:

| Value | Becomes |
|---|---|
| `10.0.0.0/8`, `2001:db8::/32` | Address · in range |
| `10.0.0.1`, `::1` | Address · is |
| `42`, `-3.5` | Number · is |
| `2026-10-22`, `2026-10-22T16:02:00Z` | Date & time · is |
| `550e8400-e29b-41d4-a716-446655440000` | UUID · is |
| `*.example.com`, `user_?` | Text · matches |
| anything else | Text · is |

A preview shows each line's type before anything is added. Blank lines are left out, and so are lines repeated in the list and values the tag already has. A value shaped like an address that does not parse, such as `10.0.0.300`, is refused rather than made a text rule. The new rules are changes like any other: **Save** writes them.

### Test a value

Under the rules, **Test a value** checks a value you type against the selected tag's rules as they are now, unsaved changes included: "Matches rule 1 and rule 2. Rule 4: 1 of 2 conditions." The value is tested as a cell of each rule's own type, so you can try a tag before any results exist. A rule with several conditions usually needs several cells, so the test says how many of its conditions the value satisfies.

## Tagging rows from results

Select rows in a result grid and choose **Add Tag…** (**Cmd+L**, in the **Edit** menu and the grid's right-click menu). A sheet lists the selected rows' columns: tick the columns whose values the tag should take. Each selected row becomes one rule, with a condition for each ticked value, its type taken from the column's type. Add the rules to an existing tag, or make a new one.

**Remove From Tag…** in the grid's right-click menu removes the rules the selected rows complete, from the tags that hold them; untick any you want to keep.

The [Inspector](inspector.md) lists the tags that match the selected row, with **Edit** and **Delete** for each.

## Appearance

**Settings > Tags** sets how many colour bands a row shows and how strongly a matched cell is tinted. See [Settings](settings.md#tags-pane).
