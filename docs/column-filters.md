---
layout: default
title: Column Filters
nav_order: 9
---

# Column Filters
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

Column filters narrow the displayed results by conditions on individual columns. Filters apply to the data already loaded in the [results grid](results-grid.md) — they don't re-run the SQL or fetch new data. The filter popover is **value-picker-first**: check the values you want, or expand the advanced section for operator-based conditions.

## Opening a Filter

Hover over a column header and click the **funnel icon** at the right edge of the type row. Columns with an active filter show a filled, accent-colored funnel at all times. Filtered results are also reflected in the action-bar status text ("V of T rows … • K filters").

## The Value Picker

The popover opens with a checklist of the column's distinct values:

- **Search** — the field at the top narrows which values are listed (it doesn't change what's checked).
- **(Select All)** — a tri-state checkbox that checks or unchecks all currently listed values.
- **(Blanks)** — NULLs and empty values are collapsed into a single "(Blanks)" row.
- **Counts** — each value shows how many rows have it. When other columns' filters are active, counts show `filtered/total`, cascading the way spreadsheet filters do.
- **Sort** — the Value/Count control in the header orders the list by value (ascending by default) or by count (descending by default); click the active segment again to flip direction.
- **Resize** — drag the grip in the bottom-right corner to enlarge the popover.

Click **Apply** to keep only rows matching the checked values (checking everything clears the filter). **Clear** resets the column's filter. When more rows remain unloaded on the server, a footer notes that counts cover only the loaded rows.

## Advanced Text Filter

Expand **Advanced text filter** at the bottom of the popover for operator-based conditions. Applying an advanced filter takes precedence over the checklist.

### Operators by Type

**String** (`text`, `varchar`, `char`, `uuid`, `inet`, `cidr`, …): contains, does not contain, contains any of, does not contain any of, starts with, ends with, equals, does not equal, is null, is not null.

**Numeric** (`integer`, `bigint`, `numeric`, `double precision`, `money`, …): equals, does not equal, less than, less than or equal, greater than, greater than or equal, between, contains any of, is null, is not null.

**Boolean**: is true, is false, is null, is not null.

**Temporal** (`date`, `time`, `timestamp`, `timestamptz`, `interval`, …): equals, less than, less than or equal, greater than, greater than or equal, between, is null, is not null.

**JSON and Array**: contains, equals, contains any of, does not contain any of, is null, is not null.

### Input Controls

The value input adapts to the column type and operator:

- **Text / numeric** — a text field; press Return to apply
- **Date** — a calendar date picker
- **Timestamp** — a calendar picker plus an HH:MM:SS time field
- **Time** — a stepper-style time picker
- **Interval** — separate day/hour/minute/second fields, compared by total seconds
- **"any of" operators** — a token field; comma or Return adds each token
- **Between** — two fields joined by "and"; both bounds inclusive

## Filter Behavior

- Filters are **client-side**, on the loaded result set. To filter at the database level, add a `WHERE` clause (or use a [chart drill-down](charts.md#drill-down-and-selection) in server mode).
- Filters on different columns combine with **AND**.
- Text comparisons are **case-insensitive**; between is inclusive; temporal values compare chronologically; intervals compare by total seconds.
- **NULLs never match value-based operators** — use is null / is not null, or the "(Blanks)" checkbox.
- Committing a chart selection in client mode applies the same kind of column filters; they show up with a "Filtered by chart" chip and can be cleared from there.
- **Reset Filters** in the action bar clears all column filters at once.
