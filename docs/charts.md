---
layout: default
title: Charts
nav_order: 10
---

# Charts
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

Any query result can be visualized as a chart without leaving Pharos. Switch a result to Chart view, map columns to chart roles, and Pharos aggregates and renders the data — either from the rows already loaded in the grid, or by pushing an aggregation query down to PostgreSQL to chart the full dataset. Charts support interactive drill-down back into the grid, customizable series colors, image export, and per-tab persistence.

## Switching Between Grid and Chart

Each result tab has a **Grid / Chart** toggle at the front of the result action bar. A new result always opens in Grid view; the chosen view mode is remembered per result tab, so you can keep one result as a chart while another stays a grid.

Chart configuration is saved along with your workspace, so a charted result reopens as the same chart after relaunching Pharos. If the cached rows for an older result are no longer stored, the chart shows a prompt to re-run the query — your column mappings are preserved.

## Chart Types

Seven chart types are available, each with its own set of column roles:

| Chart Type | Roles | Notes |
|------------|-------|-------|
| Bar | Category (X), Value (Y), Series (optional) | Aggregating; stacked when a Series is mapped |
| Line | Category (X), Value (Y), Series (optional) | Aggregating |
| Area | Category (X), Value (Y), Series (optional) | Aggregating |
| Pie | Category (X), Value (Y), Series (optional) | Aggregating |
| Scatter | X, Y, Size (optional), Color (optional) | Plots raw points, no aggregation |
| Gantt | Label, Start, End, Color (optional) | Plots raw rows, no aggregation |
| Heatmap | X (columns), Y (rows), Value (color, optional) | Aggregating; no Value column means cell counts |

Column eligibility is type-aware: Value, Y, and Size roles accept numeric columns; X, Start, and End accept numeric or temporal columns; Category, Series, Label, and Color accept any column. Text columns whose values all parse as numbers are treated as numeric.

When you first open Chart view, Pharos infers a starting configuration: a bar chart using the first categorical or temporal column as the Category and the first numeric column as the Value.

## Configuration Rail

The rail on the right side of the chart provides all configuration:

- **Chart type** — picker over the seven types.
- **Role pickers** — one per role for the selected type (labels adapt: "Category (X)", "Value (Y)", "Series (optional)", etc.). Choose "—" to unmap a role.
- **Aggregate** — Sum, Avg, Count, Min, or Max (aggregating chart types only). Aggregations other than Count require a Value column.
- **Time bucket** — shown when the axis column is temporal: None, Auto, Hour, Day, Week, Month, or Year.
- **Bins** — shown when the axis column is numeric: Off, Auto, 10, 20, or 50. Auto picks roughly √n buckets (capped at 50), and an Auto axis with 12 or fewer distinct values stays discrete instead of binning.
- **Heatmap per-axis controls** — the heatmap gets independent "X bins" / "Y bins" (or "X time bucket" / "Y time bucket") controls, so each axis can be bucketed separately.
- **Sort** — shown for bar, line, area, and pie: order points by Query order (default), Category (X label), or Value (Y total), each ascending or descending.
- **Colors** — shown for bar, line, area, pie, and scatter; see [Colors](#colors) below.
- **Server aggregation** — see below.

### Top Categories and "Other"

Categorical axes are capped at the top 25 categories by aggregate total; remaining categories are folded into a single **Other** category, and the chart is marked as truncated. Heatmaps apply the cap per axis (up to 25 × 25 cells). Binned numeric and temporal axes are not capped.

## Colors

Series colors come from a global default palette, with an optional per-chart override.

- **Default palette** — Settings → Charts holds an ordered list of colors used across all charts: a red-led, accessibility-considered six-color set out of the box. Each slot has a native color well; add or remove slots, or use **Reset to defaults** to restore the built-in set.
- **Per-chart override** — the rail's Colors section (bar, line, area, pie, and scatter) shows one color well per series, slice, or — for scatter, which plots a single color — per point. Picking a color there overrides the global palette for that chart only; **Reset to palette** clears the override and reverts to the default palette.
- Heatmaps use their own value-based color gradient instead of the palette.

## Client-Side vs Server-Side Aggregation

By default, charts aggregate **the rows currently loaded** in the result tab. If more rows exist than are loaded, an orange banner reports "Charting N of M loaded rows, aggregated client-side" with a **Load all rows** button that fetches the remaining rows into memory (up to 200,000).

For large datasets, enable **Aggregate on server** in the rail's Server aggregation section. Pharos wraps your query in a generated `GROUP BY` statement and runs it on PostgreSQL, so the chart reflects the **full dataset** regardless of how many rows are loaded in the grid.

- Server aggregation requires a single `SELECT` or `WITH` query with a category and value mapped. Gantt charts never aggregate server-side.
- Scatter charts in server mode plot a **deterministic sample** (up to 5,000 points, chosen by a stable hash so re-runs reproduce the same sample) and are flagged as sampled.
- While the query runs, a banner shows "Running server aggregation…"; on success it reports "Aggregated server-side over the full dataset, as of &lt;time&gt;" (with "truncated" or "sampled" appended when applicable). Errors appear in the same banner.
- Changing any mapping or bin setting while server mode is on re-runs the aggregation automatically (debounced).
- A reopened workspace never re-queries the database silently — the banner offers an explicit **Run server aggregation** button instead.
- **Copy Generated SQL** in the rail copies the generated push-down query to the clipboard, so you can inspect or reuse it.

## Drill-Down and Selection

Clicking a chart stages a selection rather than filtering immediately. Selected marks stay lit while everything else dims, and a commit button appears in the action bar.

### Gestures

| Chart Type | Tap | Drag |
|------------|-----|------|
| Bar / Line / Area | Select a category (series-precise on stacked bars) | Horizontal brush across categories |
| Pie | Select a slice | — |
| Heatmap | Select a cell | Rectangular marquee over cells |
| Scatter | Show a coordinate callout (no drill) | Marquee brush over an X/Y range |
| Gantt | Select a row | Drag on the time axis to brush a time window (selects overlapping bars) |

### Modifier Keys

- **Click** — replace the selection
- **⌘-click** — toggle an item in or out of the selection
- **⇧-click** — extend the selection contiguously from the anchor
- **Esc** — clear the staged selection

### Committing a Selection

The commit button's label describes exactly what will happen:

- **Filter in Grid — …** (client mode) — translates the selection into [column filters](column-filters.md), switches back to Grid view, and shows a **Filtered by chart** chip. Clicking the chip removes the chart filter and restores any manual filters it displaced.
- **Query Selected Rows — …** (server mode) — spawns a new result tab running your original query wrapped in a `WHERE` clause matching the selection. The query goes through the normal execution path, so it appears in query history and can be re-run independently.

## Exporting Charts

The export button in the action bar offers chart-specific options while Chart view is active:

- **Export Chart as PNG…** — retina PNG
- **Export Chart as PDF…** — single-page PDF
- **Copy Chart as Image** — PNG on the clipboard
- **View / Copy Generated SQL** — shown when server aggregation is on

Exports render the chart alone, with no caption or footer. File metadata is limited to generic, non-sensitive fields: PNG exports set `Software` to "Pharos" and a creation timestamp; PDF exports set `Creator` to "Pharos". No connection name, row counts, or SQL are embedded. Gantt exports render at full content height so no rows are clipped.
