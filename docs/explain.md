---
layout: default
title: EXPLAIN Visualization
nav_order: 8
---

# EXPLAIN Visualization
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

When you run an `EXPLAIN` query, Pharos automatically renders the query plan as an interactive visual tree instead of raw JSON.

## EXPLAIN Variants

Pharos supports all PostgreSQL EXPLAIN options:

| Command | What It Shows |
|:--------|:-------------|
| `EXPLAIN SELECT ...` | Estimated costs and row counts |
| `EXPLAIN ANALYZE SELECT ...` | Actual timing, row counts, and loops |
| `EXPLAIN (ANALYZE, BUFFERS) SELECT ...` | Timing plus shared buffer hit/read stats |
| `EXPLAIN (ANALYZE, VERBOSE) SELECT ...` | Timing plus verbose output |

{: .note }
`EXPLAIN ANALYZE` actually executes the query, so use with caution on write operations.

Pharos injects `FORMAT JSON` automatically so the output can be parsed into a visual tree. If you already specify a `FORMAT`, Pharos leaves your query unchanged.

## Visual Tree

The plan is displayed as a collapsible tree with each node representing a plan operation.

### Node Display

Each node shows:
- **Icon** — Visual indicator for the operation type (e.g., sequential scan, index scan, nested loop, hash join)
- **Node type** — The PostgreSQL operation name (e.g., `Seq Scan`, `Index Scan`, `Hash Join`)
- **Relation** — Table or index being accessed, with schema prefix
- **Alias** — Shown in parentheses when different from the relation name
- **Join type** — For join nodes (e.g., Inner, Left, Right)
- **Index name** — For index scan operations

### Cost Bar

Each node has a proportional cost/time bar:
- **EXPLAIN only** — Bar shows estimated cost relative to the root total cost (blue)
- **EXPLAIN ANALYZE** — Bar shows actual time relative to the root total time, color-coded:

| Color | Meaning |
|:------|:--------|
| Green | Less than 10% of total time |
| Amber | 10–50% of total time |
| Red | More than 50% of total time |

### Statistics

Each node displays relevant metrics:

**EXPLAIN only:**
- Startup and total cost estimates
- Estimated row count

**EXPLAIN ANALYZE:**
- Actual execution time (with loop multiplier if loops > 1)
- Actual row count
- Row estimate accuracy warning when actual rows differ by more than 10x from estimated
- Buffer statistics (shared hits and reads) when BUFFERS option is used

### Filters and Conditions

When present, nodes display:
- **Filter** — Row filter expression with count of rows removed
- **Index Cond** — Index condition being applied

## Summary Bar

When available (EXPLAIN ANALYZE), a summary bar at the top shows:
- **Planning Time** — Time spent planning the query
- **Execution Time** — Time spent executing
- **Total** — Combined planning + execution time

## Raw JSON View

Toggle between **Visual** and **Raw JSON** views using the buttons in the header. The Raw JSON view shows the complete EXPLAIN output formatted with indentation.

## Expand / Collapse

Click any node with children to expand or collapse its subtree. All nodes start expanded by default for full visibility.
