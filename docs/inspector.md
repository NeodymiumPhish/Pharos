---
layout: default
title: Inspector
nav_order: 11
---

# Inspector
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

The Inspector is the rightmost pane of the window. It shows a detailed view of whatever is selected: a single grid row as labeled key-value pairs, a multi-row (or chart) selection as per-column aggregate statistics, or details for a schema object selected in the navigator.

## Opening the Inspector

Toggle the Inspector with **Cmd+Opt+0**, via **View > Toggle Inspector**, or with the toolbar button. It is collapsed by default and updates live as the selection changes.

## Single-Row Detail

When exactly one row is selected in the results grid, the Inspector shows **Row Detail** with a position counter (e.g., "3 of 150"). Every column appears as a key-value pair — the column name and type as the key, the cell value in monospace with type-aware coloring:

| Type Category | Color |
|---------------|-------|
| Numeric | Blue |
| Boolean true / false | Green / Red (per the Bool Display setting) |
| Temporal | Purple |
| JSON | Orange |
| Array | Secondary gray |
| String | Default |
| NULL | Italic gray (per the NULL Display setting) |
| Empty string | "(empty string)" in gray, to distinguish from NULL |

**Double-click** any value to copy it (a brief "Copied" confirmation appears), or **right-click** for a Copy menu item with a preview of the value.

## Selection Summary

When two or more rows are selected — or when you select marks in a [chart](charts.md) — the Inspector switches to **Selection Summary** with per-column statistics. Every column shows **Count**, **Distinct**, and (when nulls exist) **NULL**, each on its own line. When a column has exactly one distinct value in the selection, the value itself is shown instead of "Distinct: 1".

Additional statistics by type:

- **Numeric** — Min, Max, Sum, and Avg (blue)
- **Temporal** — Earliest and Latest (purple); skipped for intervals
- **Boolean** — True and False counts (green/red)
- **String / JSON / Array** — count and distinct only

## Schema Details

Selecting a table, partition, or column in the [Schema Browser](schema-browser.md) shows its details in the Inspector, and selecting a result in [Results History](query-history.md) previews its SQL there.

## No Selection

With nothing selected, the Inspector shows a "No Selection" placeholder.

{: .tip }
Select a numeric column's cells in the grid — or brush a region of a chart — and the Inspector gives you instant sum/average/min/max without writing an aggregate query.
