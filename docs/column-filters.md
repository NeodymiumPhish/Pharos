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

Column filters allow you to narrow the displayed results by applying conditions to individual columns. Filters are applied to the data already loaded in the [results grid](results-grid.md) -- they do not re-run the SQL query or fetch new data from the server.

## Accessing Filters

Each column header in the results grid has a filter icon on its trailing edge:

- **On hover** -- a subtle filter icon appears when the pointer enters a column header
- **Active filter** -- columns with an active filter display a filled, accent-colored icon that remains visible at all times
- **Click the icon** to open the filter popover for that column

The filter popover shows the column name, an operator menu, value input fields, and Apply/Clear buttons.

## Filter Operators by Type

The available filter operators depend on the column's PostgreSQL data type. The table below lists all operators for each type category.

### String

Applies to `text`, `varchar`, `char`, `uuid`, `inet`, `cidr`, and other text-like types.

| Operator | Description |
|----------|-------------|
| contains | Value includes the search text (case-insensitive) |
| does not contain | Value does not include the search text |
| contains any of | Value includes at least one of the provided tokens |
| does not contain any of | Value does not include any of the provided tokens |
| starts with | Value begins with the search text |
| ends with | Value ends with the search text |
| equals | Value exactly matches the search text (case-insensitive) |
| does not equal | Value does not match the search text |
| is null | Value is NULL |
| is not null | Value is not NULL |

### Numeric

Applies to `integer`, `bigint`, `smallint`, `real`, `double precision`, `numeric`, `decimal`, `money`, `serial`, and `bigserial`.

| Operator | Description |
|----------|-------------|
| equals | Value equals the filter number |
| does not equal | Value does not equal the filter number |
| less than | Value is less than the filter number |
| less than or equal | Value is less than or equal to the filter number |
| greater than | Value is greater than the filter number |
| greater than or equal | Value is greater than or equal to the filter number |
| between | Value falls within the specified range (inclusive) |
| contains any of | Value equals at least one of the provided numbers |
| is null | Value is NULL |
| is not null | Value is not NULL |

### Boolean

Applies to `boolean` columns.

| Operator | Description |
|----------|-------------|
| is true | Value is true |
| is false | Value is false |
| is null | Value is NULL |
| is not null | Value is not NULL |

### Temporal

Applies to `date`, `time`, `timetz`, `timestamp`, `timestamptz`, and `interval`.

| Operator | Description |
|----------|-------------|
| equals | Value equals the filter date/time |
| less than | Value is before the filter date/time |
| less than or equal | Value is on or before the filter date/time |
| greater than | Value is after the filter date/time |
| greater than or equal | Value is on or after the filter date/time |
| between | Value falls within the specified date/time range (inclusive) |
| is null | Value is NULL |
| is not null | Value is not NULL |

### JSON and Array

Applies to `json`, `jsonb`, and array types (e.g., `integer[]`, `text[]`).

| Operator | Description |
|----------|-------------|
| contains | Value includes the search text |
| equals | Value exactly matches the search text |
| contains any of | Value includes at least one of the provided tokens |
| does not contain any of | Value does not include any of the provided tokens |
| is null | Value is NULL |
| is not null | Value is not NULL |

## Input Controls

The value input area adapts to the column's data type and the selected operator.

### Text and Numeric Columns

A standard text field for entering the filter value. Press **Return** to apply.

### Date Columns

A native calendar date picker for selecting a date visually.

### Timestamp Columns

A calendar date picker for the date portion, plus a text field for the time component in HH:MM:SS format.

### Time Columns

A stepper-style time picker for selecting hours, minutes, and seconds.

### Interval Columns

Four separate numeric fields for days, hours, minutes, and seconds. The interval is converted to total seconds for comparison.

### Multi-Value Operators

Operators like "contains any of" and "does not contain any of" use a token field. Type a value and press **comma** or **Return** to add it as a token. Each token is matched independently.

### Between Operator

Two value fields separated by an "and" label. Both bounds are inclusive.

## Filter Behavior

- Filters are applied **client-side** on the currently loaded result set. They do not modify the SQL query or re-fetch data from the server.
- Multiple column filters across different columns combine with **AND** logic -- a row must match all active filters to be displayed.
- Text comparisons are **case-insensitive**.
- Numeric "between" is **inclusive** on both ends.
- Temporal columns (except intervals) compare values using ISO string lexicographic ordering, which preserves chronological order for standard date and timestamp formats.
- Interval comparisons convert values to total seconds for accurate ordering.
- **NULL values never match value-based operators.** Use "is null" or "is not null" to filter by nullability.

{: .note }
> Column filters work on the currently loaded result set. They do not modify the SQL query or re-fetch data from the server. To filter at the database level, add a `WHERE` clause to your query.
