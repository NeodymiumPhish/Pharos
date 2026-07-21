---
layout: default
title: History & Workspaces
nav_order: 14
---

# History & Workspaces
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

The **Results History** panel is the second panel of the sidebar (clock icon). Pharos records your work as **workspaces**: one workspace per editor-tab session, capturing the editor text, its [query variables](query-variables.md), and every result the tab produced. Reopening a workspace restores the whole session — SQL, variables, result tabs, even chart configurations.

## Workspaces

Each workspace row shows its name with a subtitle like "4 queries · 2h ago · Local Dev". Workspaces are named after their connection automatically (e.g., "analytics", or "analytics +1" if a second database was also queried); rename them to anything you like.

- **Reopen** — double-click a workspace to restore it as a live editor tab with all of its result tabs rebuilt. If the workspace is already open, Pharos focuses that tab instead. Double-clicking a specific result in the preview reopens the workspace focused on that result.
- **Preview** — selecting a workspace lists its results in the lower half of the panel: each with its color dot, label, and column/row counts. Selecting a result previews its SQL in the [Inspector](inspector.md).
- **Context menu** — **Rename…**, **Duplicate**, and **Delete** (multi-select supported for deleting several at once). Individual results in the preview offer **Copy SQL** and **Delete this result**.

## Cached Results

Result data is cached with each workspace, so reopening usually shows the original rows instantly without re-executing anything. Caches are bounded (per-result and per-workspace limits); when a workspace exceeds its budget, its oldest results are demoted to "SQL only" — they reopen as re-runnable tabs marked stale instead of showing cached data.

## Earlier History

Below the workspaces, an **"Earlier history"** disclosure holds individual query entries that predate workspaces (and auxiliary queries such as chart server-aggregation runs). Each entry shows the column count and table names, plus row count, relative time, and connection. Double-click one to open it in a tab — cached results display immediately when available. Right-click for **Copy SQL** or **Delete**; multi-select to batch delete.

## What Gets Recorded

Successful queries are recorded automatically; failed queries are not. History is retained for **90 days** — older workspaces and entries are pruned automatically.

## Filtering

The sidebar's **Filter** field searches history by SQL text and workspace names.
