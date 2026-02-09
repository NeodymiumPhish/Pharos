import { useRef, useMemo, useCallback, useState, useEffect, forwardRef, useImperativeHandle } from 'react';
import { useVirtualizer } from '@tanstack/react-virtual';
import { Download, Copy, AlertCircle, WrapText, AlignLeft, Pin, PinOff, Maximize2, Minimize2, ChevronUp, ChevronDown, RotateCcw, Check, Filter, X, Hash, Columns3 } from 'lucide-react';
import { save } from '@tauri-apps/plugin-dialog';
import { cn } from '@/lib/cn';
import * as tauri from '@/lib/tauri';
import { useSettingsStore } from '@/stores/settingsStore';
import type { ExportFormat } from '@/lib/types';
import type { QueryResults } from '@/stores/editorStore';

interface ResultsGridProps {
  results: QueryResults | null;
  error: string | null;
  executionTime: number | null;
  isExecuting: boolean;
  isPinned?: boolean;
  pinnedTabName?: string;
  canPin?: boolean;
  onPin?: () => void;
  onUnpin?: () => void;
  isExpanded?: boolean;
  onToggleExpand?: () => void;
  onLoadMore?: () => void;
  isLoadingMore?: boolean;
}

// Cell selection as a rectangular range
interface CellSelection {
  startRow: number;
  startCol: number;
  endRow: number;
  endCol: number;
}

export interface ResultsGridRef {
  copyToClipboard: () => Promise<void>;
  exportCSV: () => void;
  exportData: (format: ExportFormat) => void;
}

// Constants for column width calculation
const MIN_COLUMN_WIDTH = 60;
const MAX_COLUMN_WIDTH = 500; // Used for initial auto-width calculation only
const AUTO_FIT_MAX_WIDTH = 800; // Maximum width when auto-fitting (double-click)
const DEFAULT_COLUMN_WIDTH = 150;
const CHAR_WIDTH = 7.5; // Approximate width of a monospace character
const COLUMN_PADDING = 32; // px for padding on both sides
const SAMPLE_ROWS = 100; // Number of rows to sample for width calculation
const ROW_NUMBER_WIDTH = 50; // Width of the row number column

function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(ms < 10_000 ? 2 : 1)}s`;
  const totalSeconds = ms / 1000;
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  if (ms < 3_600_000) {
    return seconds >= 0.5 ? `${minutes}m ${seconds.toFixed(1)}s` : `${minutes}m`;
  }
  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  return remainingMinutes > 0 ? `${hours}h ${remainingMinutes}m` : `${hours}h`;
}

function formatCellValue(value: unknown): string {
  if (value === null) {
    return 'NULL';
  }
  if (value === undefined) {
    return '';
  }
  if (typeof value === 'boolean') {
    return value ? 'true' : 'false';
  }
  if (typeof value === 'object') {
    return JSON.stringify(value);
  }
  return String(value);
}

// Get display value based on newline mode
function getDisplayValue(value: unknown, showNewlines: boolean): string {
  const formatted = formatCellValue(value);
  if (showNewlines) {
    return formatted;
  }
  // Replace newlines with a visible indicator when newlines are hidden
  return formatted.replace(/\r?\n/g, '↵ ');
}

function getCellClassName(value: unknown): string {
  if (value === null) {
    return 'text-theme-text-muted italic';
  }
  if (typeof value === 'number') {
    return 'text-blue-400';
  }
  if (typeof value === 'boolean') {
    return 'text-violet-400';
  }
  return 'text-theme-text-secondary';
}

// Calculate optimal column width based on content
function calculateColumnWidth(
  columnName: string,
  dataType: string,
  rows: Record<string, unknown>[],
  sampleSize: number
): number {
  // Start with header width (column name + data type)
  const headerWidth = Math.max(columnName.length, dataType.length) * CHAR_WIDTH + COLUMN_PADDING;

  let maxContentWidth = headerWidth;

  // Sample rows to find max content width
  const samplesToCheck = Math.min(sampleSize, rows.length);
  for (let i = 0; i < samplesToCheck; i++) {
    const value = formatCellValue(rows[i][columnName]);
    // For multi-line content, use the longest line
    const lines = value.split(/\r?\n/);
    const longestLine = lines.reduce((max, line) => Math.max(max, line.length), 0);
    const contentWidth = longestLine * CHAR_WIDTH + COLUMN_PADDING;
    maxContentWidth = Math.max(maxContentWidth, contentWidth);
  }

  // Clamp to min/max bounds
  return Math.max(MIN_COLUMN_WIDTH, Math.min(MAX_COLUMN_WIDTH, maxContentWidth));
}

// Calculate optimal column width for auto-fit (double-click) - checks all rows
function calculateAutoFitWidth(
  columnName: string,
  dataType: string,
  rows: Record<string, unknown>[],
  showNewlines: boolean
): number {
  // Start with header width
  const headerWidth = Math.max(columnName.length, dataType.length) * CHAR_WIDTH + COLUMN_PADDING;

  let maxContentWidth = headerWidth;

  // Check ALL rows for auto-fit (user explicitly requested precision)
  for (let i = 0; i < rows.length; i++) {
    const value = formatCellValue(rows[i][columnName]);

    let effectiveLength: number;
    if (showNewlines) {
      // When Lines mode is on, use the widest individual line
      const lines = value.split(/\r?\n/);
      effectiveLength = lines.reduce((max, line) => Math.max(max, line.length), 0);
    } else {
      // When Lines mode is off, line breaks are replaced with "↵ "
      // Use the widest individual line since that's what determines visual width
      const lines = value.split(/\r?\n/);
      effectiveLength = lines.reduce((max, line) => Math.max(max, line.length), 0);
    }

    const contentWidth = effectiveLength * CHAR_WIDTH + COLUMN_PADDING;
    maxContentWidth = Math.max(maxContentWidth, contentWidth);
  }

  // Clamp to min and auto-fit max
  return Math.max(MIN_COLUMN_WIDTH, Math.min(AUTO_FIT_MAX_WIDTH, maxContentWidth));
}

// ============================================================================
// Column Filter Types & Helpers
// ============================================================================

type FilterOperator =
  | 'contains' | 'equals' | 'startsWith' | 'endsWith'
  | 'eq' | 'neq' | 'gt' | 'lt' | 'gte' | 'lte' | 'between'
  | 'isTrue' | 'isFalse'
  | 'isNull' | 'isNotNull';

interface ColumnFilter {
  column: string;
  operator: FilterOperator;
  value: string;
  value2?: string; // For "between"
}

const NUMERIC_TYPES = new Set(['int2', 'int4', 'int8', 'float4', 'float8', 'numeric', 'decimal', 'smallint', 'integer', 'bigint', 'real', 'double precision', 'serial', 'bigserial']);
const BOOLEAN_TYPES = new Set(['bool', 'boolean']);

function getAvailableOperators(dataType: string): { value: FilterOperator; label: string }[] {
  const dt = dataType.toLowerCase();
  const universal: { value: FilterOperator; label: string }[] = [
    { value: 'isNull', label: 'Is NULL' },
    { value: 'isNotNull', label: 'Is not NULL' },
  ];

  if (BOOLEAN_TYPES.has(dt)) {
    return [
      { value: 'isTrue', label: 'Is true' },
      { value: 'isFalse', label: 'Is false' },
      ...universal,
    ];
  }

  if (NUMERIC_TYPES.has(dt)) {
    return [
      { value: 'eq', label: '=' },
      { value: 'neq', label: '!=' },
      { value: 'gt', label: '>' },
      { value: 'lt', label: '<' },
      { value: 'gte', label: '>=' },
      { value: 'lte', label: '<=' },
      { value: 'between', label: 'Between' },
      ...universal,
    ];
  }

  // Default: text operators
  return [
    { value: 'contains', label: 'Contains' },
    { value: 'equals', label: 'Equals' },
    { value: 'startsWith', label: 'Starts with' },
    { value: 'endsWith', label: 'Ends with' },
    ...universal,
  ];
}

function applyFilter(cellValue: unknown, filter: ColumnFilter): boolean {
  // Universal operators
  if (filter.operator === 'isNull') return cellValue === null || cellValue === undefined;
  if (filter.operator === 'isNotNull') return cellValue !== null && cellValue !== undefined;

  // Null values don't match any non-null filter
  if (cellValue === null || cellValue === undefined) return false;

  // Boolean operators
  if (filter.operator === 'isTrue') return cellValue === true;
  if (filter.operator === 'isFalse') return cellValue === false;

  // Numeric operators
  if (['eq', 'neq', 'gt', 'lt', 'gte', 'lte', 'between'].includes(filter.operator)) {
    const num = typeof cellValue === 'number' ? cellValue : parseFloat(String(cellValue));
    const target = parseFloat(filter.value);
    if (isNaN(num) || isNaN(target)) return false;

    switch (filter.operator) {
      case 'eq': return num === target;
      case 'neq': return num !== target;
      case 'gt': return num > target;
      case 'lt': return num < target;
      case 'gte': return num >= target;
      case 'lte': return num <= target;
      case 'between': {
        const target2 = parseFloat(filter.value2 ?? '');
        if (isNaN(target2)) return false;
        return num >= Math.min(target, target2) && num <= Math.max(target, target2);
      }
    }
  }

  // Text operators
  const cellStr = formatCellValue(cellValue).toLowerCase();
  const filterVal = filter.value.toLowerCase();

  switch (filter.operator) {
    case 'contains': return cellStr.includes(filterVal);
    case 'equals': return cellStr === filterVal;
    case 'startsWith': return cellStr.startsWith(filterVal);
    case 'endsWith': return cellStr.endsWith(filterVal);
    default: return true;
  }
}

function getFilterLabel(filter: ColumnFilter): string {
  const ops: Record<FilterOperator, string> = {
    contains: 'contains', equals: '=', startsWith: 'starts with', endsWith: 'ends with',
    eq: '=', neq: '!=', gt: '>', lt: '<', gte: '>=', lte: '<=', between: 'between',
    isTrue: 'is true', isFalse: 'is false', isNull: 'is NULL', isNotNull: 'is not NULL',
  };
  const op = ops[filter.operator] ?? filter.operator;
  if (['isNull', 'isNotNull', 'isTrue', 'isFalse'].includes(filter.operator)) {
    return `${filter.column} ${op}`;
  }
  if (filter.operator === 'between') {
    return `${filter.column} ${op} ${filter.value} and ${filter.value2 ?? ''}`;
  }
  return `${filter.column} ${op} "${filter.value}"`;
}

// ============================================================================
// Filter Popover Component
// ============================================================================

interface FilterPopoverProps {
  column: string;
  dataType: string;
  currentFilter: ColumnFilter | null;
  onApply: (filter: ColumnFilter) => void;
  onClear: () => void;
  onClose: () => void;
}

const FilterPopover = forwardRef<HTMLDivElement, FilterPopoverProps>(function FilterPopover(
  { column, dataType, currentFilter, onApply, onClear, onClose },
  ref
) {
  const operators = getAvailableOperators(dataType);
  const [operator, setOperator] = useState<FilterOperator>(currentFilter?.operator ?? operators[0].value);
  const [value, setValue] = useState(currentFilter?.value ?? '');
  const [value2, setValue2] = useState(currentFilter?.value2 ?? '');

  const needsValue = !['isNull', 'isNotNull', 'isTrue', 'isFalse'].includes(operator);
  const needsValue2 = operator === 'between';

  const handleApply = () => {
    if (needsValue && !value.trim()) return;
    if (needsValue2 && !value2.trim()) return;
    onApply({ column, operator, value, value2: needsValue2 ? value2 : undefined });
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      handleApply();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      onClose();
    }
  };

  return (
    <div
      ref={ref}
      className="absolute left-0 top-full mt-1 w-56 rounded-md border border-theme-border-secondary bg-theme-bg-elevated shadow-lg z-50 p-2 space-y-2"
      onClick={(e) => e.stopPropagation()}
    >
      <select
        className="w-full px-2 py-1 rounded text-[11px] bg-theme-bg-surface text-theme-text-primary border border-theme-border-primary outline-none"
        value={operator}
        onChange={(e) => setOperator(e.target.value as FilterOperator)}
      >
        {operators.map((op) => (
          <option key={op.value} value={op.value}>{op.label}</option>
        ))}
      </select>

      {needsValue && (
        <input
          type="text"
          autoFocus
          className="w-full px-2 py-1 rounded text-[11px] bg-theme-bg-surface text-theme-text-primary border border-theme-border-primary outline-none placeholder:text-theme-text-muted"
          placeholder="Value..."
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={handleKeyDown}
        />
      )}

      {needsValue2 && (
        <input
          type="text"
          className="w-full px-2 py-1 rounded text-[11px] bg-theme-bg-surface text-theme-text-primary border border-theme-border-primary outline-none placeholder:text-theme-text-muted"
          placeholder="Upper bound..."
          value={value2}
          onChange={(e) => setValue2(e.target.value)}
          onKeyDown={handleKeyDown}
        />
      )}

      <div className="flex items-center gap-1.5">
        <button
          onClick={handleApply}
          className="flex-1 px-2 py-1 rounded text-[11px] bg-blue-600 hover:bg-blue-500 text-white transition-colors"
        >
          Apply
        </button>
        {currentFilter && (
          <button
            onClick={onClear}
            className="flex-1 px-2 py-1 rounded text-[11px] bg-theme-bg-hover hover:bg-theme-bg-active text-theme-text-secondary transition-colors"
          >
            Clear
          </button>
        )}
      </div>
    </div>
  );
});

export const ResultsGrid = forwardRef<ResultsGridRef, ResultsGridProps>(function ResultsGrid(
  { results, error, executionTime, isExecuting, isPinned, pinnedTabName, canPin, onPin, onUnpin, isExpanded, onToggleExpand, onLoadMore, isLoadingMore },
  ref
) {
  const parentRef = useRef<HTMLDivElement>(null);
  const [wrapText, setWrapText] = useState(false);
  const [showNewlines, setShowNewlines] = useState(false);
  const [columnWidths, setColumnWidths] = useState<Record<string, number>>({});
  const [resizingColumn, setResizingColumn] = useState<string | null>(null);

  // Cell selection state
  const [selection, setSelection] = useState<CellSelection | null>(null);
  const [isSelecting, setIsSelecting] = useState(false);
  const justFinishedSelectingRef = useRef(false);

  // Sorting state
  const [sortColumn, setSortColumn] = useState<string | null>(null);
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc' | null>(null);

  // Column filter state
  const [filters, setFilters] = useState<Map<string, ColumnFilter>>(new Map());
  const [filterPopoverColumn, setFilterPopoverColumn] = useState<string | null>(null);
  const filterPopoverRef = useRef<HTMLDivElement>(null);

  // Copy feedback state
  const [showCopyFeedback, setShowCopyFeedback] = useState(false);

  // Row numbering state
  const [showRowNumbers, setShowRowNumbers] = useState(true);

  // Column visibility state
  const [hiddenColumns, setHiddenColumns] = useState<Set<string>>(new Set());
  const [showColumnPicker, setShowColumnPicker] = useState(false);
  const columnPickerRef = useRef<HTMLDivElement>(null);

  // Settings
  const zebraStriping = useSettingsStore((state) => state.settings.ui.zebraStriping);

  // Calculate initial column widths based on content
  const initialColumnWidths = useMemo(() => {
    if (!results) return {};
    const widths: Record<string, number> = {};
    results.columns.forEach((col) => {
      widths[col.name] = calculateColumnWidth(
        col.name,
        col.dataType,
        results.rows,
        SAMPLE_ROWS
      );
    });
    return widths;
  }, [results]);

  // Use user-adjusted widths if available, otherwise use calculated widths
  const effectiveColumnWidths = useMemo(() => {
    if (!results) return {};
    const widths: Record<string, number> = {};
    results.columns.forEach((col) => {
      widths[col.name] = columnWidths[col.name] ?? initialColumnWidths[col.name] ?? DEFAULT_COLUMN_WIDTH;
    });
    return widths;
  }, [results, columnWidths, initialColumnWidths]);

  // Visible columns (excluding hidden ones)
  const visibleColumns = useMemo(() => {
    if (!results) return [];
    return results.columns.filter((c) => !hiddenColumns.has(c.name));
  }, [results, hiddenColumns]);

  // Calculate total table width
  const totalTableWidth = useMemo(() => {
    if (!results) return 0;
    const dataWidth = visibleColumns.reduce((sum, col) => sum + (effectiveColumnWidths[col.name] ?? DEFAULT_COLUMN_WIDTH), 0);
    return dataWidth + (showRowNumbers ? ROW_NUMBER_WIDTH : 0);
  }, [results, visibleColumns, effectiveColumnWidths, showRowNumbers]);

  // Compute filtered rows
  const filteredRows = useMemo(() => {
    if (!results || filters.size === 0) return results?.rows ?? [];
    return results.rows.filter((row) => {
      for (const filter of filters.values()) {
        if (!applyFilter(row[filter.column], filter)) return false;
      }
      return true;
    });
  }, [results, filters]);

  // Compute sorted rows (operates on filteredRows)
  const sortedRows = useMemo(() => {
    if (!sortColumn || !sortDirection) {
      return filteredRows;
    }

    const rows = [...filteredRows]; // Copy to avoid mutating

    rows.sort((a, b) => {
      const aVal = a[sortColumn];
      const bVal = b[sortColumn];

      // Handle nulls - nulls sort to the end regardless of direction
      if (aVal === null && bVal === null) return 0;
      if (aVal === null) return 1;
      if (bVal === null) return -1;

      // Compare based on type
      let comparison = 0;

      if (typeof aVal === 'number' && typeof bVal === 'number') {
        comparison = aVal - bVal;
      } else if (typeof aVal === 'boolean' && typeof bVal === 'boolean') {
        comparison = (aVal === bVal) ? 0 : (aVal ? 1 : -1);
      } else {
        // String comparison for everything else (including dates which are strings from JSON)
        const aStr = formatCellValue(aVal);
        const bStr = formatCellValue(bVal);
        comparison = aStr.localeCompare(bStr, undefined, { numeric: true, sensitivity: 'base' });
      }

      return sortDirection === 'desc' ? -comparison : comparison;
    });

    return rows;
  }, [results, sortColumn, sortDirection]);

  // Compute aggregates for selected cells
  const aggregates = useMemo(() => {
    if (!selection || !results) return null;

    const minRow = Math.min(selection.startRow, selection.endRow);
    const maxRow = Math.max(selection.startRow, selection.endRow);
    const minCol = Math.min(selection.startCol, selection.endCol);
    const maxCol = Math.max(selection.startCol, selection.endCol);

    // Map selection column indices to visible columns
    const selectedCols = visibleColumns.slice(minCol, maxCol + 1);
    const selectedRows = sortedRows.slice(minRow, maxRow + 1);

    let count = 0;
    let numericCount = 0;
    let sum = 0;
    let min = Infinity;
    let max = -Infinity;

    for (const row of selectedRows) {
      for (const col of selectedCols) {
        const val = row[col.name];
        if (val !== null && val !== undefined) {
          count++;
          const num = typeof val === 'number' ? val : parseFloat(String(val));
          if (!isNaN(num)) {
            numericCount++;
            sum += num;
            if (num < min) min = num;
            if (num > max) max = num;
          }
        }
      }
    }

    if (count === 0) return null;

    return {
      count,
      numericCount,
      sum: numericCount > 0 ? sum : null,
      avg: numericCount > 0 ? sum / numericCount : null,
      min: numericCount > 0 ? min : null,
      max: numericCount > 0 ? max : null,
    };
  }, [selection, results, sortedRows, visibleColumns]);

  // Handle column resize
  const handleColumnResizeStart = useCallback((e: React.MouseEvent, columnName: string) => {
    e.preventDefault();
    e.stopPropagation();
    setResizingColumn(columnName);

    const startX = e.clientX;
    const startWidth = effectiveColumnWidths[columnName] ?? DEFAULT_COLUMN_WIDTH;

    const handleMouseMove = (moveEvent: MouseEvent) => {
      const delta = moveEvent.clientX - startX;
      const newWidth = Math.max(MIN_COLUMN_WIDTH, startWidth + delta); // No max constraint - user can resize as wide as they want
      setColumnWidths((prev) => ({
        ...prev,
        [columnName]: newWidth,
      }));
    };

    const handleMouseUp = () => {
      setResizingColumn(null);
      document.removeEventListener('mousemove', handleMouseMove);
      document.removeEventListener('mouseup', handleMouseUp);
    };

    document.addEventListener('mousemove', handleMouseMove);
    document.addEventListener('mouseup', handleMouseUp);
  }, [effectiveColumnWidths]);

  // Handle double-click on column resize handle to auto-fit width
  const handleColumnDoubleClick = useCallback((e: React.MouseEvent, columnName: string) => {
    e.preventDefault();
    e.stopPropagation();

    if (!results) return;

    const column = results.columns.find(c => c.name === columnName);
    if (!column) return;

    const autoFitWidth = calculateAutoFitWidth(
      columnName,
      column.dataType,
      results.rows,
      showNewlines
    );

    setColumnWidths(prev => ({
      ...prev,
      [columnName]: autoFitWidth,
    }));
  }, [results, showNewlines]);

  // Cell selection handlers
  const handleCellMouseDown = useCallback((rowIndex: number, colIndex: number, e: React.MouseEvent) => {
    e.preventDefault(); // Prevent text selection

    if (e.shiftKey && selection) {
      // Extend existing selection from anchor to clicked cell
      setSelection({
        ...selection,
        endRow: rowIndex,
        endCol: colIndex,
      });
    } else {
      // New selection
      setSelection({
        startRow: rowIndex,
        startCol: colIndex,
        endRow: rowIndex,
        endCol: colIndex,
      });
    }
    setIsSelecting(true);
  }, [selection]);

  const handleCellMouseEnter = useCallback((rowIndex: number, colIndex: number) => {
    if (!isSelecting || !selection) return;
    setSelection(prev => prev ? { ...prev, endRow: rowIndex, endCol: colIndex } : null);
  }, [isSelecting, selection]);

  // Check if a cell is within the selection
  const isCellSelected = useCallback((rowIndex: number, colIndex: number): boolean => {
    if (!selection) return false;
    const minRow = Math.min(selection.startRow, selection.endRow);
    const maxRow = Math.max(selection.startRow, selection.endRow);
    const minCol = Math.min(selection.startCol, selection.endCol);
    const maxCol = Math.max(selection.startCol, selection.endCol);
    return rowIndex >= minRow && rowIndex <= maxRow && colIndex >= minCol && colIndex <= maxCol;
  }, [selection]);

  // Stop selection when mouse is released (document-level listener)
  useEffect(() => {
    if (!isSelecting) return;

    const handleMouseUp = () => {
      setIsSelecting(false);
      // Mark that we just finished selecting so click handler doesn't clear selection
      justFinishedSelectingRef.current = true;
      // Reset the flag after a short delay (after click event fires)
      setTimeout(() => {
        justFinishedSelectingRef.current = false;
      }, 0);
    };

    document.addEventListener('mouseup', handleMouseUp);
    return () => document.removeEventListener('mouseup', handleMouseUp);
  }, [isSelecting]);

  // Calculate dynamic row height based on content when showing newlines or wrapping
  const getRowHeight = useCallback((index: number): number => {
    if (!results) return 24;

    // If neither wrap nor newlines is enabled, use fixed height
    if (!showNewlines && !wrapText) return 24;

    const row = sortedRows[index];
    let maxLines = 1;

    for (const col of results.columns) {
      const value = formatCellValue(row[col.name]);
      const colWidth = effectiveColumnWidths[col.name] ?? DEFAULT_COLUMN_WIDTH;
      // Account for padding (16px total = 8px each side from px-2)
      const availableWidth = colWidth - 16;
      // Characters that fit per line (using CHAR_WIDTH constant)
      const charsPerLine = Math.max(1, Math.floor(availableWidth / CHAR_WIDTH));

      let lineCount = 1;

      if (showNewlines) {
        // Count actual newlines in content
        const lines = value.split(/\r?\n/);
        if (wrapText) {
          // For each line, calculate how many wrapped lines it produces
          lineCount = lines.reduce((total, line) => {
            const wrappedLines = Math.max(1, Math.ceil(line.length / charsPerLine));
            return total + wrappedLines;
          }, 0);
        } else {
          lineCount = lines.length;
        }
      } else if (wrapText) {
        // No newlines shown, but wrapping enabled - wrap the entire string
        // Replace newlines with the indicator for length calculation
        const displayValue = value.replace(/\r?\n/g, '↵ ');
        lineCount = Math.max(1, Math.ceil(displayValue.length / charsPerLine));
      }

      maxLines = Math.max(maxLines, lineCount);
    }

    // Only expand if there are actually multiple lines
    if (maxLines <= 1) return 24;

    // Base height + additional height per line (approximately 14px per line)
    // Cap at 300px height (roughly 20+ lines)
    return Math.min(24 + (maxLines - 1) * 14, 300);
  }, [showNewlines, wrapText, results, effectiveColumnWidths, sortedRows]);

  const rowVirtualizer = useVirtualizer({
    count: sortedRows.length,
    getScrollElement: () => parentRef.current,
    estimateSize: getRowHeight,
    overscan: 10,
    getItemKey: useCallback((index: number) => index, []),
  });

  // Recalculate virtualizer when display options change
  useEffect(() => {
    if (results) {
      rowVirtualizer.measure();
    }
  }, [showNewlines, wrapText, effectiveColumnWidths, results, rowVirtualizer]);

  // Reset sort, filters, and column visibility when results change (new query executed)
  useEffect(() => {
    setSortColumn(null);
    setSortDirection(null);
    setFilters(new Map());
    setFilterPopoverColumn(null);
    setHiddenColumns(new Set());
  }, [results]);

  // Close filter popover on outside click
  useEffect(() => {
    if (!filterPopoverColumn) return;
    const handleClickOutside = (e: MouseEvent) => {
      if (filterPopoverRef.current && !filterPopoverRef.current.contains(e.target as Node)) {
        setFilterPopoverColumn(null);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [filterPopoverColumn]);

  // Close column picker on outside click
  useEffect(() => {
    if (!showColumnPicker) return;
    const handleClickOutside = (e: MouseEvent) => {
      if (columnPickerRef.current && !columnPickerRef.current.contains(e.target as Node)) {
        setShowColumnPicker(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [showColumnPicker]);

  const handleCopyToClipboard = useCallback(async () => {
    if (!results) return;

    const header = results.columns.map((c) => c.name).join('\t');
    const rows = results.rows
      .map((row) =>
        results.columns.map((col) => formatCellValue(row[col.name])).join('\t')
      )
      .join('\n');

    const text = `${header}\n${rows}`;
    await navigator.clipboard.writeText(text);

    // Show copy feedback
    setShowCopyFeedback(true);
    setTimeout(() => setShowCopyFeedback(false), 1500);
  }, [results]);

  // Copy only selected cells with their column headers (unless single column)
  const handleCopySelection = useCallback(async () => {
    if (!results || !selection) return;

    const minRow = Math.min(selection.startRow, selection.endRow);
    const maxRow = Math.max(selection.startRow, selection.endRow);
    const minCol = Math.min(selection.startCol, selection.endCol);
    const maxCol = Math.max(selection.startCol, selection.endCol);

    // Get selected columns (from visible columns, which is what the user sees)
    const selectedColumns = visibleColumns.slice(minCol, maxCol + 1);
    const isSingleColumn = minCol === maxCol;

    // Data rows (from sortedRows which respects filter/sort)
    const rows = sortedRows.slice(minRow, maxRow + 1).map(row =>
      selectedColumns.map(col => formatCellValue(row[col.name])).join('\t')
    ).join('\n');

    // Skip header for single column selection
    if (isSingleColumn) {
      await navigator.clipboard.writeText(rows);
    } else {
      const header = selectedColumns.map(c => c.name).join('\t');
      await navigator.clipboard.writeText(`${header}\n${rows}`);
    }

    // Show copy feedback
    setShowCopyFeedback(true);
    setTimeout(() => setShowCopyFeedback(false), 1500);
  }, [results, selection]);

  // Copy button: copy selection if present, otherwise copy all
  const handleCopyButtonClick = useCallback(async () => {
    if (selection) {
      await handleCopySelection();
    } else {
      await handleCopyToClipboard();
    }
  }, [selection, handleCopySelection, handleCopyToClipboard]);

  // Keyboard handler for Cmd+C and Escape
  useEffect(() => {
    const container = parentRef.current;
    if (!container) return;

    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'c' && selection) {
        e.preventDefault();
        handleCopySelection();
      } else if (e.key === 'Escape' && selection) {
        e.preventDefault();
        setSelection(null);
      }
    };

    container.addEventListener('keydown', handleKeyDown);
    return () => container.removeEventListener('keydown', handleKeyDown);
  }, [selection, handleCopySelection]);

  // Clear selection when clicking header or empty area
  // Handle click on column header (for sorting)
  const handleHeaderClick = useCallback((columnName?: string) => {
    // If clicking the header area (not a specific column), just clear selection
    if (!columnName) {
      setSelection(null);
      return;
    }

    // Toggle sort for the clicked column
    if (sortColumn === columnName) {
      // Cycle: asc -> desc -> null (original order)
      if (sortDirection === 'asc') {
        setSortDirection('desc');
      } else if (sortDirection === 'desc') {
        setSortColumn(null);
        setSortDirection(null);
      }
    } else {
      // New column: start with ascending
      setSortColumn(columnName);
      setSortDirection('asc');
    }

    // Also clear cell selection when sorting
    setSelection(null);
  }, [sortColumn, sortDirection]);

  // Reset sort to original query order
  const handleResetSort = useCallback(() => {
    setSortColumn(null);
    setSortDirection(null);
  }, []);

  // Clear selection when clicking empty area in the scroll container
  const handleContainerClick = useCallback((e: React.MouseEvent) => {
    // Don't clear if we just finished a drag selection
    if (justFinishedSelectingRef.current) return;
    // Only clear if clicking directly on the container, not on a cell
    if (e.target === e.currentTarget) {
      setSelection(null);
    }
  }, []);

  // Client-side text export for CSV/TSV/JSON/JSON Lines/SQL INSERT/Markdown
  const generateTextExport = useCallback((format: ExportFormat): { content: string; mimeType: string; ext: string } | null => {
    if (!results) return null;

    const escapeCSV = (value: string, delimiter: string): string => {
      if (value.includes(delimiter) || value.includes('"') || value.includes('\n')) {
        return `"${value.replace(/"/g, '""')}"`;
      }
      return value;
    };

    switch (format) {
      case 'csv':
      case 'tsv': {
        const delim = format === 'tsv' ? '\t' : ',';
        const header = results.columns.map((c) => escapeCSV(c.name, delim)).join(delim);
        const rows = results.rows
          .map((row) =>
            results.columns.map((col) => escapeCSV(formatCellValue(row[col.name]), delim)).join(delim)
          )
          .join('\n');
        return {
          content: `${header}\n${rows}`,
          mimeType: format === 'tsv' ? 'text/tab-separated-values;charset=utf-8;' : 'text/csv;charset=utf-8;',
          ext: format,
        };
      }
      case 'json': {
        const jsonRows = results.rows.map((row) => {
          const obj: Record<string, unknown> = {};
          results.columns.forEach((col) => { obj[col.name] = row[col.name] ?? null; });
          return obj;
        });
        return { content: JSON.stringify(jsonRows, null, 2), mimeType: 'application/json;charset=utf-8;', ext: 'json' };
      }
      case 'jsonLines': {
        const lines = results.rows.map((row) => {
          const obj: Record<string, unknown> = {};
          results.columns.forEach((col) => { obj[col.name] = row[col.name] ?? null; });
          return JSON.stringify(obj);
        }).join('\n');
        return { content: lines, mimeType: 'application/x-ndjson;charset=utf-8;', ext: 'jsonl' };
      }
      case 'sqlInsert': {
        const colList = results.columns.map((c) => `"${c.name.replace(/"/g, '""')}"`).join(', ');
        const stmts = results.rows.map((row) => {
          const vals = results.columns.map((col) => {
            const v = row[col.name];
            if (v === null || v === undefined) return 'NULL';
            if (typeof v === 'number') return String(v);
            if (typeof v === 'boolean') return v ? 'true' : 'false';
            return `'${String(v).replace(/'/g, "''")}'`;
          }).join(', ');
          return `INSERT INTO (${colList}) VALUES (${vals});`;
        }).join('\n');
        return { content: stmts, mimeType: 'text/sql;charset=utf-8;', ext: 'sql' };
      }
      case 'markdown': {
        const headers = results.columns.map((c) => c.name);
        const headerRow = `| ${headers.join(' | ')} |`;
        const sepRow = `| ${headers.map(() => '---').join(' | ')} |`;
        const dataRows = results.rows.map((row) => {
          const vals = results.columns.map((col) => formatCellValue(row[col.name]).replace(/\|/g, '\\|').replace(/\n/g, ' '));
          return `| ${vals.join(' | ')} |`;
        }).join('\n');
        return { content: `${headerRow}\n${sepRow}\n${dataRows}`, mimeType: 'text/markdown;charset=utf-8;', ext: 'md' };
      }
      default:
        return null;
    }
  }, [results]);

  const handleExportData = useCallback(async (format: ExportFormat) => {
    if (!results) return;

    const filterMap: Record<ExportFormat, { name: string; extensions: string[] }> = {
      csv: { name: 'CSV Files', extensions: ['csv'] },
      tsv: { name: 'TSV Files', extensions: ['tsv'] },
      json: { name: 'JSON Files', extensions: ['json'] },
      jsonLines: { name: 'JSON Lines Files', extensions: ['jsonl'] },
      sqlInsert: { name: 'SQL Files', extensions: ['sql'] },
      markdown: { name: 'Markdown Files', extensions: ['md'] },
      xlsx: { name: 'Excel Files', extensions: ['xlsx'] },
    };
    const extMap: Record<ExportFormat, string> = {
      csv: 'csv', tsv: 'tsv', json: 'json', jsonLines: 'jsonl',
      sqlInsert: 'sql', markdown: 'md', xlsx: 'xlsx',
    };

    const savePath = await save({
      defaultPath: `query_results.${extMap[format]}`,
      filters: [filterMap[format]],
    });
    if (!savePath) return;

    if (format === 'xlsx') {
      try {
        await tauri.exportResults({
          columns: results.columns.map((c) => ({ name: c.name, dataType: c.dataType })),
          rows: results.rows,
          filePath: savePath,
        });
      } catch (err) {
        console.error('Failed to export XLSX:', err);
      }
      return;
    }

    // Text formats — generate content and write to chosen path
    const exported = generateTextExport(format);
    if (!exported) return;

    try {
      await tauri.writeTextExport(savePath, exported.content);
    } catch (err) {
      console.error('Failed to write export file:', err);
    }
  }, [results, generateTextExport]);

  const handleExportCSV = useCallback(() => {
    handleExportData('csv');
  }, [handleExportData]);

  // Export dropdown state
  const [showExportMenu, setShowExportMenu] = useState(false);
  const exportMenuRef = useRef<HTMLDivElement>(null);

  // Close export menu on outside click
  useEffect(() => {
    if (!showExportMenu) return;
    const handleClickOutside = (e: MouseEvent) => {
      if (exportMenuRef.current && !exportMenuRef.current.contains(e.target as Node)) {
        setShowExportMenu(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [showExportMenu]);

  // Expose methods to parent via ref
  useImperativeHandle(ref, () => ({
    copyToClipboard: handleCopyToClipboard,
    exportCSV: handleExportCSV,
    exportData: handleExportData,
  }), [handleCopyToClipboard, handleExportCSV, handleExportData]);

  if (isExecuting) {
    return (
      <div className="h-full flex items-center justify-center text-theme-text-tertiary text-xs">
        <div className="flex items-center gap-2">
          <div className="w-4 h-4 border-2 border-theme-text-muted border-t-theme-text-secondary rounded-full animate-spin" />
          <span>Executing query...</span>
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="h-full flex items-center justify-center p-4">
        <div className="max-w-lg bg-red-950/50 border border-red-900/50 rounded-lg p-3">
          <div className="flex items-start gap-2">
            <AlertCircle className="w-4 h-4 text-red-400 flex-shrink-0 mt-0.5" />
            <div>
              <h3 className="text-red-300 font-medium text-xs mb-1">Query Error</h3>
              <p className="text-red-200/70 text-[11px] font-mono whitespace-pre-wrap">{error}</p>
            </div>
          </div>
        </div>
      </div>
    );
  }

  if (!results) {
    return (
      <div className="h-full flex items-center justify-center text-theme-text-muted text-xs">
        <p>Run a query to see results</p>
      </div>
    );
  }

  if (results.rows.length === 0) {
    return (
      <div className="h-full flex flex-col">
        <div className="flex items-center justify-between px-3 py-1.5 border-b border-theme-border-primary">
          <span className="text-xs text-theme-text-tertiary">
            0 rows {executionTime !== null && `(${formatDuration(executionTime)})`}
          </span>
        </div>
        <div className="flex-1 flex items-center justify-center text-theme-text-muted text-xs">
          <p>Query returned no rows</p>
        </div>
      </div>
    );
  }

  return (
    <div className="h-full w-full flex flex-col overflow-hidden" style={{ maxWidth: '100%' }}>
      {/* Toolbar - fixed, doesn't scroll */}
      <div className="flex items-center justify-between px-3 py-1 border-b border-theme-border-primary flex-shrink-0 flex-grow-0">
        <div className="flex items-center gap-2">
          {onToggleExpand && (
            <button
              onClick={onToggleExpand}
              className="p-1 rounded hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary transition-colors"
              title={isExpanded ? "Collapse results" : "Expand results"}
            >
              {isExpanded ? <Minimize2 className="w-3.5 h-3.5" /> : <Maximize2 className="w-3.5 h-3.5" />}
            </button>
          )}
          <span className="text-xs text-theme-text-secondary">
            {filters.size > 0
              ? `${filteredRows.length.toLocaleString()} of ${results.rowCount.toLocaleString()} rows`
              : `${results.rowCount.toLocaleString()} row${results.rowCount !== 1 ? 's' : ''}`}
            {results.hasMore && '+'}
            {executionTime !== null && (
              <span className="text-theme-text-tertiary ml-1.5">({formatDuration(executionTime)})</span>
            )}
          </span>
          {isPinned && pinnedTabName && (
            <span className="text-xs text-amber-500 flex items-center gap-1">
              <Pin className="w-3 h-3" />
              Pinned to: {pinnedTabName}
            </span>
          )}
        </div>
        <div className="flex items-center gap-0.5">
          {sortColumn !== null && (
            <button
              onClick={handleResetSort}
              className="flex items-center gap-1 px-2 py-1 rounded text-[11px] text-blue-400 bg-blue-500/10 hover:bg-blue-500/20 transition-colors"
              title="Reset to original query order"
            >
              <RotateCcw className="w-3 h-3" />
              Reset Sort
            </button>
          )}
          {isPinned ? (
            <button
              onClick={onUnpin}
              className="flex items-center gap-1 px-2 py-1 rounded text-[11px] text-amber-500 bg-amber-500/10 hover:bg-amber-500/20 transition-colors"
              title="Unpin results"
            >
              <PinOff className="w-3 h-3" />
              Unpin
            </button>
          ) : canPin ? (
            <button
              onClick={onPin}
              className="flex items-center gap-1 px-2 py-1 rounded text-[11px] text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover transition-colors"
              title="Pin these results while working in other tabs"
            >
              <Pin className="w-3 h-3" />
              Pin
            </button>
          ) : null}
          <button
            onClick={() => setShowRowNumbers(!showRowNumbers)}
            className={cn(
              'flex items-center gap-1 px-2 py-1 rounded text-[11px] transition-colors',
              showRowNumbers
                ? 'text-theme-text-primary bg-theme-bg-active'
                : 'text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover'
            )}
            title={showRowNumbers ? 'Hide row numbers' : 'Show row numbers'}
          >
            <Hash className="w-3 h-3" />
            Rows
          </button>
          <div className="relative" ref={columnPickerRef}>
            <button
              onClick={() => setShowColumnPicker(!showColumnPicker)}
              className={cn(
                'flex items-center gap-1 px-2 py-1 rounded text-[11px] transition-colors',
                hiddenColumns.size > 0
                  ? 'text-blue-400 bg-blue-500/10'
                  : 'text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover'
              )}
              title="Toggle column visibility"
            >
              <Columns3 className="w-3 h-3" />
              Columns
              {hiddenColumns.size > 0 && (
                <span className="text-[9px] bg-blue-500/20 px-1 rounded">{visibleColumns.length}/{results.columns.length}</span>
              )}
            </button>
            {showColumnPicker && (
              <div className="absolute right-0 top-full mt-1 w-52 max-h-64 overflow-y-auto rounded-md border border-theme-border-secondary bg-theme-bg-elevated shadow-lg z-50 py-1">
                <div className="flex items-center justify-between px-3 py-1 border-b border-theme-border-primary">
                  <button
                    className="text-[10px] text-blue-400 hover:text-blue-300"
                    onClick={() => setHiddenColumns(new Set())}
                  >
                    Show All
                  </button>
                  <button
                    className="text-[10px] text-theme-text-muted hover:text-theme-text-secondary"
                    onClick={() => setHiddenColumns(new Set(results.columns.map((c) => c.name)))}
                  >
                    Hide All
                  </button>
                </div>
                {results.columns.map((col) => (
                  <label
                    key={col.name}
                    className="flex items-center gap-2 px-3 py-1 text-[11px] text-theme-text-secondary hover:bg-theme-bg-hover cursor-pointer"
                  >
                    <input
                      type="checkbox"
                      checked={!hiddenColumns.has(col.name)}
                      onChange={() => {
                        setHiddenColumns((prev) => {
                          const next = new Set(prev);
                          if (next.has(col.name)) {
                            next.delete(col.name);
                          } else {
                            next.add(col.name);
                          }
                          return next;
                        });
                      }}
                      className="rounded border-theme-border-primary"
                    />
                    <span className="truncate">{col.name}</span>
                    <span className="text-[9px] text-theme-text-tertiary font-mono ml-auto">{col.dataType}</span>
                  </label>
                ))}
              </div>
            )}
          </div>
          <button
            onClick={() => setWrapText(!wrapText)}
            className={cn(
              'flex items-center gap-1 px-2 py-1 rounded text-[11px] transition-colors',
              wrapText
                ? 'text-theme-text-primary bg-theme-bg-active'
                : 'text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover'
            )}
            title={wrapText ? 'Disable text wrapping' : 'Enable text wrapping'}
          >
            <WrapText className="w-3 h-3" />
            Wrap
          </button>
          <button
            onClick={() => setShowNewlines(!showNewlines)}
            className={cn(
              'flex items-center gap-1 px-2 py-1 rounded text-[11px] transition-colors',
              showNewlines
                ? 'text-theme-text-primary bg-theme-bg-active'
                : 'text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover'
            )}
            title={showNewlines ? 'Hide line breaks' : 'Show line breaks'}
          >
            <AlignLeft className="w-3 h-3" />
            Lines
          </button>
          <button
            onClick={handleCopyButtonClick}
            className={cn(
              'flex items-center gap-1 px-2 py-1 rounded text-[11px] transition-colors',
              showCopyFeedback
                ? 'text-green-400 bg-green-500/10'
                : 'text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover'
            )}
            title={selection ? "Copy selected cells" : "Copy all to clipboard"}
          >
            {showCopyFeedback ? (
              <>
                <Check className="w-3 h-3" />
                Copied!
              </>
            ) : (
              <>
                <Copy className="w-3 h-3" />
                {selection ? 'Copy Selection' : 'Copy'}
              </>
            )}
          </button>
          <div className="relative" ref={exportMenuRef}>
            <button
              onClick={() => setShowExportMenu(!showExportMenu)}
              className="flex items-center gap-1 px-2 py-1 rounded text-[11px] text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover transition-colors"
              title="Export results"
            >
              <Download className="w-3 h-3" />
              Export
              <ChevronDown className="w-3 h-3" />
            </button>
            {showExportMenu && (
              <div className="absolute right-0 top-full mt-1 w-40 rounded-md border border-theme-border-secondary bg-theme-bg-elevated shadow-lg z-50 py-1">
                {([
                  { format: 'csv' as ExportFormat, label: 'CSV (.csv)' },
                  { format: 'tsv' as ExportFormat, label: 'TSV (.tsv)' },
                  { format: 'json' as ExportFormat, label: 'JSON (.json)' },
                  { format: 'jsonLines' as ExportFormat, label: 'JSON Lines (.jsonl)' },
                  { format: 'sqlInsert' as ExportFormat, label: 'SQL INSERT (.sql)' },
                  { format: 'markdown' as ExportFormat, label: 'Markdown (.md)' },
                  { format: 'xlsx' as ExportFormat, label: 'Excel (.xlsx)' },
                ]).map(({ format: fmt, label }) => (
                  <button
                    key={fmt}
                    onClick={() => { handleExportData(fmt); setShowExportMenu(false); }}
                    className="w-full text-left px-3 py-1.5 text-[11px] text-theme-text-secondary hover:bg-theme-bg-hover hover:text-theme-text-primary transition-colors"
                  >
                    {label}
                  </button>
                ))}
              </div>
            )}
          </div>
        </div>
      </div>

      {/* Active filter chips */}
      {filters.size > 0 && (
        <div className="flex items-center gap-1.5 px-3 py-1 border-b border-theme-border-primary flex-shrink-0 flex-wrap">
          <span className="text-[10px] text-theme-text-muted">Filters:</span>
          {Array.from(filters.values()).map((filter) => (
            <span
              key={filter.column}
              className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded bg-blue-500/10 text-blue-400 text-[10px] font-mono"
            >
              {getFilterLabel(filter)}
              <button
                className="hover:text-blue-300"
                onClick={() => {
                  setFilters((prev) => {
                    const next = new Map(prev);
                    next.delete(filter.column);
                    return next;
                  });
                }}
              >
                <X className="w-3 h-3" />
              </button>
            </span>
          ))}
          <button
            className="text-[10px] text-theme-text-muted hover:text-theme-text-secondary ml-1"
            onClick={() => setFilters(new Map())}
          >
            Clear All
          </button>
        </div>
      )}

      {/* Table - scrollable area */}
      <div className="flex-1 min-h-0 overflow-hidden">
        <div ref={parentRef} className="h-full overflow-auto outline-none" tabIndex={0} onClick={handleContainerClick}>
          {/* Inner container - sets the scrollable width */}
          <div style={{ width: Math.max(totalTableWidth, 1), minWidth: totalTableWidth }} onClick={handleContainerClick}>
            {/* Header row - sticky */}
            <div
              className="sticky top-0 z-10 bg-theme-bg-elevated flex border-b border-theme-border-primary"
              style={{ width: totalTableWidth }}
              onClick={() => handleHeaderClick()}
            >
              {/* Row number header */}
              {showRowNumbers && (
                <div
                  className="px-2 py-1 text-center text-[11px] font-medium text-theme-text-tertiary border-r border-theme-border-primary whitespace-nowrap flex-shrink-0 select-none"
                  style={{ width: ROW_NUMBER_WIDTH, minWidth: ROW_NUMBER_WIDTH }}
                >
                  #
                </div>
              )}
              {visibleColumns.map((col) => (
                <div
                  key={col.name}
                  className={cn(
                    'relative px-2 py-1 text-left text-[11px] font-medium text-theme-text-secondary border-r border-theme-border-primary whitespace-nowrap flex-shrink-0 group cursor-pointer select-none',
                    sortColumn === col.name && 'bg-theme-bg-active'
                  )}
                  style={{ width: effectiveColumnWidths[col.name], minWidth: effectiveColumnWidths[col.name] }}
                  onClick={(e) => {
                    e.stopPropagation();
                    handleHeaderClick(col.name);
                  }}
                >
                  <div className="flex items-center gap-1.5">
                    <span className="truncate">{col.name}</span>
                    <span className="text-theme-text-tertiary font-normal text-[10px]">{col.dataType}</span>
                    {/* Filter icon */}
                    <button
                      className={cn(
                        'flex-shrink-0 p-0.5 rounded transition-colors',
                        filters.has(col.name)
                          ? 'text-blue-400 opacity-100'
                          : 'text-theme-text-muted opacity-0 group-hover:opacity-100 hover:text-theme-text-secondary'
                      )}
                      onClick={(e) => {
                        e.stopPropagation();
                        setFilterPopoverColumn(filterPopoverColumn === col.name ? null : col.name);
                      }}
                      title="Filter column"
                    >
                      <Filter className="w-3 h-3" />
                    </button>
                    {/* Sort indicator */}
                    {sortColumn === col.name && (
                      <span className="ml-auto flex-shrink-0">
                        {sortDirection === 'asc' ? (
                          <ChevronUp className="w-3 h-3 text-theme-text-secondary" />
                        ) : (
                          <ChevronDown className="w-3 h-3 text-theme-text-secondary" />
                        )}
                      </span>
                    )}
                  </div>
                  {/* Filter popover */}
                  {filterPopoverColumn === col.name && (
                    <FilterPopover
                      ref={filterPopoverRef}
                      column={col.name}
                      dataType={col.dataType}
                      currentFilter={filters.get(col.name) ?? null}
                      onApply={(filter) => {
                        setFilters((prev) => {
                          const next = new Map(prev);
                          next.set(col.name, filter);
                          return next;
                        });
                        setFilterPopoverColumn(null);
                      }}
                      onClear={() => {
                        setFilters((prev) => {
                          const next = new Map(prev);
                          next.delete(col.name);
                          return next;
                        });
                        setFilterPopoverColumn(null);
                      }}
                      onClose={() => setFilterPopoverColumn(null)}
                    />
                  )}
                  {/* Resize handle */}
                  <div
                    className={cn(
                      'absolute right-0 top-0 bottom-0 w-1 cursor-col-resize transition-colors',
                      'hover:bg-blue-500/50',
                      resizingColumn === col.name && 'bg-blue-500'
                    )}
                    onMouseDown={(e) => handleColumnResizeStart(e, col.name)}
                    onDoubleClick={(e) => handleColumnDoubleClick(e, col.name)}
                  />
                </div>
              ))}
            </div>

            {/* Virtual rows container */}
            <div
              style={{
                height: `${rowVirtualizer.getTotalSize()}px`,
                position: 'relative',
                width: totalTableWidth,
              }}
              onClick={handleContainerClick}
            >
              {rowVirtualizer.getVirtualItems().map((virtualRow) => {
                const row = sortedRows[virtualRow.index];
                return (
                  <div
                    key={virtualRow.key}
                    className={cn(
                      'flex hover:bg-theme-bg-hover',
                      zebraStriping && virtualRow.index % 2 === 1 && 'bg-theme-bg-hover'
                    )}
                    style={{
                      position: 'absolute',
                      top: 0,
                      left: 0,
                      width: totalTableWidth,
                      height: `${virtualRow.size}px`,
                      transform: `translateY(${virtualRow.start}px)`,
                    }}
                  >
                    {/* Row number cell */}
                    {showRowNumbers && (
                      <div
                        className="px-1 py-0.5 text-[11px] font-mono text-theme-text-muted border-b border-r border-theme-border-primary flex-shrink-0 text-right select-none"
                        style={{ width: ROW_NUMBER_WIDTH, minWidth: ROW_NUMBER_WIDTH }}
                      >
                        {virtualRow.index + 1}
                      </div>
                    )}
                    {visibleColumns.map((col, colIndex) => (
                      <div
                        key={col.name}
                        className={cn(
                          'px-2 py-0.5 text-[11px] font-mono border-b border-r border-theme-border-primary flex-shrink-0 text-left overflow-hidden cursor-cell select-none',
                          wrapText ? 'break-words' : 'text-ellipsis',
                          wrapText || showNewlines ? 'whitespace-pre-wrap' : 'whitespace-nowrap',
                          getCellClassName(row[col.name]),
                          isCellSelected(virtualRow.index, colIndex) && 'bg-blue-500/20 outline outline-1 -outline-offset-1 outline-blue-500/50'
                        )}
                        style={{ width: effectiveColumnWidths[col.name], minWidth: effectiveColumnWidths[col.name] }}
                        title={formatCellValue(row[col.name])}
                        onMouseDown={(e) => handleCellMouseDown(virtualRow.index, colIndex, e)}
                        onMouseEnter={() => handleCellMouseEnter(virtualRow.index, colIndex)}
                      >
                        {getDisplayValue(row[col.name], showNewlines)}
                      </div>
                    ))}
                  </div>
                );
              })}
            </div>

            {/* Load More bar */}
            {results.hasMore && (
              <div className="flex items-center justify-center py-3 border-b border-theme-border-primary">
                {isLoadingMore ? (
                  <div className="flex items-center gap-2 text-xs text-theme-text-muted">
                    <div className="w-3 h-3 border-2 border-theme-text-muted border-t-theme-text-secondary rounded-full animate-spin" />
                    Loading more rows...
                  </div>
                ) : (
                  <button
                    onClick={onLoadMore}
                    className="px-4 py-1.5 rounded text-[11px] text-theme-text-secondary bg-theme-bg-hover hover:bg-theme-bg-active transition-colors"
                  >
                    Load more rows
                  </button>
                )}
              </div>
            )}
          </div>
        </div>
      </div>

      {/* Aggregate footer */}
      {aggregates && (
        <div className="flex items-center gap-4 px-3 py-1 border-t border-theme-border-primary flex-shrink-0 text-[11px] text-theme-text-muted font-mono">
          <span>Count: {aggregates.count.toLocaleString()}</span>
          {aggregates.sum !== null && (
            <>
              <span>Sum: {aggregates.sum.toLocaleString(undefined, { maximumFractionDigits: 4 })}</span>
              <span>Avg: {aggregates.avg!.toLocaleString(undefined, { maximumFractionDigits: 4 })}</span>
              <span>Min: {aggregates.min!.toLocaleString(undefined, { maximumFractionDigits: 4 })}</span>
              <span>Max: {aggregates.max!.toLocaleString(undefined, { maximumFractionDigits: 4 })}</span>
            </>
          )}
        </div>
      )}
    </div>
  );
});
