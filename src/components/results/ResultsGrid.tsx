import { useRef, useMemo, useCallback, useState, useEffect, forwardRef, useImperativeHandle } from 'react';
import { useVirtualizer } from '@tanstack/react-virtual';
import { Download, Copy, AlertCircle, WrapText, AlignLeft, Pin, PinOff, Maximize2, Minimize2, ChevronUp, ChevronDown, RotateCcw, Check, Filter, X, Hash, Columns3, Search, Pencil, Trash2, Lock } from 'lucide-react';
import { cn } from '@/lib/cn';
import { useSettingsStore } from '@/stores/settingsStore';
import type { EditableInfo, RowEdit } from '@/lib/types';
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
  editableInfo?: EditableInfo;
  pendingEdits?: RowEdit[];
  onCellEdit?: (rowIndex: number, columnName: string, newValue: unknown) => void;
  onDeleteRows?: (rowIndices: number[]) => void;
  onCommitEdits?: () => void;
  onDiscardEdits?: () => void;
  onExport?: () => void;
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

function formatCellValue(value: unknown, nullDisplay: string = 'NULL'): string {
  if (value === null) {
    return nullDisplay;
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
function getDisplayValue(value: unknown, showNewlines: boolean, nullDisplay: string = 'NULL'): string {
  const formatted = formatCellValue(value, nullDisplay);
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
    return 'text-blue-700 dark:text-blue-300';
  }
  if (typeof value === 'boolean') {
    return 'text-violet-700 dark:text-violet-300';
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
const TEMPORAL_TYPES = new Set([
  'timestamp', 'timestamptz', 'timestamp without time zone', 'timestamp with time zone',
  'date', 'time', 'timetz', 'time without time zone', 'time with time zone',
]);
const IP_TYPES = new Set(['inet', 'cidr']);
const TEXT_TYPES = new Set([
  'text', 'varchar', 'char', 'bpchar', 'name', 'xml', 'character varying', 'character',
]);

type AggregateMode = 'numeric' | 'temporal' | 'ip' | 'boolean' | 'text' | 'mixed';

interface BaseAggregates { mode: AggregateMode; count: number }
interface NumericAggregates extends BaseAggregates { mode: 'numeric'; sum: number; avg: number; min: number; max: number }
interface TemporalAggregates extends BaseAggregates { mode: 'temporal'; min: string; max: string; duration: string }
interface IpAggregates extends BaseAggregates { mode: 'ip'; unique: number; min: string; max: string }
interface BooleanAggregates extends BaseAggregates { mode: 'boolean'; trueCount: number; falseCount: number }
interface TextAggregates extends BaseAggregates { mode: 'text'; unique: number; minLength: number; maxLength: number }
interface MixedAggregates extends BaseAggregates { mode: 'mixed'; unique: number }
type Aggregates = NumericAggregates | TemporalAggregates | IpAggregates | BooleanAggregates | TextAggregates | MixedAggregates;

function getAggregateCategory(dataType: string): AggregateMode {
  const dt = dataType.toLowerCase();
  if (NUMERIC_TYPES.has(dt)) return 'numeric';
  if (TEMPORAL_TYPES.has(dt)) return 'temporal';
  if (IP_TYPES.has(dt)) return 'ip';
  if (BOOLEAN_TYPES.has(dt)) return 'boolean';
  if (TEXT_TYPES.has(dt)) return 'text';
  return 'text';
}

function resolveAggregateMode(columns: { dataType: string }[]): AggregateMode {
  const categories = new Set(columns.map(c => getAggregateCategory(c.dataType)));
  if (categories.size === 1) return categories.values().next().value!;
  return 'mixed';
}

function parseTemporalToMs(value: string, dataType: string): number | null {
  const dt = dataType.toLowerCase();
  let d: Date;
  if (dt === 'time' || dt === 'timetz' || dt === 'time without time zone' || dt === 'time with time zone') {
    d = new Date(`1970-01-01T${value}`);
  } else {
    d = new Date(value);
  }
  return isNaN(d.getTime()) ? null : d.getTime();
}

function ipToNumber(ipStr: string): number | null {
  const ip = ipStr.split('/')[0];
  const parts = ip.split('.');
  if (parts.length !== 4) return null;
  const nums = parts.map(Number);
  if (nums.some(n => isNaN(n) || n < 0 || n > 255)) return null;
  return ((nums[0] << 24) | (nums[1] << 16) | (nums[2] << 8) | nums[3]) >>> 0;
}

function formatAggregateDuration(ms: number): string {
  if (ms < 0) ms = -ms;
  const seconds = Math.floor(ms / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);
  if (days > 0) {
    const rh = hours % 24, rm = minutes % 60;
    return `${days}d` + (rh > 0 ? ` ${rh}h` : '') + (rm > 0 ? ` ${rm}m` : '');
  }
  if (hours > 0) {
    const rm = minutes % 60;
    return rm > 0 ? `${hours}h ${rm}m` : `${hours}h`;
  }
  if (minutes > 0) {
    const rs = seconds % 60;
    return rs > 0 ? `${minutes}m ${rs}s` : `${minutes}m`;
  }
  return `${seconds}s`;
}

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
  const cellStr = formatCellValue(cellValue, 'NULL').toLowerCase();
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
  { results, error, executionTime, isExecuting, isPinned, pinnedTabName, canPin, onPin, onUnpin, isExpanded, onToggleExpand, onLoadMore, isLoadingMore, editableInfo, pendingEdits, onCellEdit, onDeleteRows, onCommitEdits, onDiscardEdits, onExport },
  ref
) {
  const parentRef = useRef<HTMLDivElement>(null);
  const wrapperRef = useRef<HTMLDivElement>(null);
  const [wrapText, setWrapText] = useState(false);
  const [showNewlines, setShowNewlines] = useState(false);
  const [columnWidths, setColumnWidths] = useState<Record<string, number>>({});
  const [resizingColumn, setResizingColumn] = useState<string | null>(null);
  const justResizedRef = useRef(false);

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
  const [showCopyMenu, setShowCopyMenu] = useState(false);
  const copyMenuRef = useRef<HTMLDivElement>(null);

  // Row numbering state
  const [showRowNumbers, setShowRowNumbers] = useState(true);

  // Column visibility state
  const [hiddenColumns, setHiddenColumns] = useState<Set<string>>(new Set());
  const [showColumnPicker, setShowColumnPicker] = useState(false);
  const columnPickerRef = useRef<HTMLDivElement>(null);

  // Settings
  const zebraStriping = useSettingsStore((state) => state.settings.ui.zebraStriping);
  const nullDisplay = useSettingsStore((state) => state.settings.ui.nullDisplay ?? 'NULL');
  const resultsFontSize = useSettingsStore((state) => state.settings.ui.resultsFontSize ?? 11);

  // Find in results state
  const [findQuery, setFindQuery] = useState('');
  const [isFindOpen, setIsFindOpen] = useState(false);
  const [currentMatchIndex, setCurrentMatchIndex] = useState(0);
  const findInputRef = useRef<HTMLInputElement | null>(null);

  // Inline edit state
  const [editingCell, setEditingCell] = useState<{ rowIndex: number; colIndex: number } | null>(null);
  const [editValue, setEditValue] = useState('');
  const editInputRef = useRef<HTMLInputElement | null>(null);

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
  }, [filteredRows, sortColumn, sortDirection]);

  // Compute type-aware aggregates for selected cells
  const aggregates = useMemo((): Aggregates | null => {
    if (!selection || !results) return null;

    const minRow = Math.min(selection.startRow, selection.endRow);
    const maxRow = Math.max(selection.startRow, selection.endRow);
    const minCol = Math.min(selection.startCol, selection.endCol);
    const maxCol = Math.max(selection.startCol, selection.endCol);

    const selectedCols = visibleColumns.slice(minCol, maxCol + 1);
    const selectedRows = sortedRows.slice(minRow, maxRow + 1);
    if (selectedCols.length === 0 || selectedRows.length === 0) return null;

    const mode = resolveAggregateMode(selectedCols);

    // Collect non-null values
    const values: unknown[] = [];
    for (const row of selectedRows) {
      for (const col of selectedCols) {
        const val = row[col.name];
        if (val !== null && val !== undefined) values.push(val);
      }
    }
    if (values.length === 0) return null;
    const count = values.length;

    switch (mode) {
      case 'numeric': {
        let sum = 0, min = Infinity, max = -Infinity, nc = 0;
        for (const val of values) {
          const num = typeof val === 'number' ? val : parseFloat(String(val));
          if (!isNaN(num)) { nc++; sum += num; if (num < min) min = num; if (num > max) max = num; }
        }
        if (nc === 0) return { mode: 'mixed', count, unique: new Set(values.map(String)).size };
        return { mode: 'numeric', count, sum, avg: sum / nc, min, max };
      }
      case 'temporal': {
        let minMs = Infinity, maxMs = -Infinity, minStr = '', maxStr = '';
        const refType = selectedCols[0].dataType;
        for (const val of values) {
          const str = String(val);
          const ms = parseTemporalToMs(str, refType);
          if (ms !== null) {
            if (ms < minMs) { minMs = ms; minStr = str; }
            if (ms > maxMs) { maxMs = ms; maxStr = str; }
          }
        }
        if (minMs === Infinity) return { mode: 'mixed', count, unique: new Set(values.map(String)).size };
        return { mode: 'temporal', count, min: minStr, max: maxStr, duration: formatAggregateDuration(maxMs - minMs) };
      }
      case 'ip': {
        const unique = new Set(values.map(String)).size;
        let minIp: string | null = null, maxIp: string | null = null;
        let minNum = Infinity, maxNum = -Infinity, allParsed = true;
        for (const val of values) {
          const str = String(val);
          const num = ipToNumber(str);
          if (num !== null) {
            if (num < minNum) { minNum = num; minIp = str; }
            if (num > maxNum) { maxNum = num; maxIp = str; }
          } else { allParsed = false; }
        }
        if (!allParsed || minIp === null) {
          const sorted = values.map(String).sort((a, b) => a.localeCompare(b));
          minIp = sorted[0]; maxIp = sorted[sorted.length - 1];
        }
        return { mode: 'ip', count, unique, min: minIp!, max: maxIp! };
      }
      case 'boolean': {
        let trueCount = 0, falseCount = 0;
        for (const val of values) { if (val === true) trueCount++; else if (val === false) falseCount++; }
        return { mode: 'boolean', count, trueCount, falseCount };
      }
      case 'text': {
        const unique = new Set(values.map(String)).size;
        let minLen = Infinity, maxLen = -Infinity;
        for (const val of values) { const len = String(val).length; if (len < minLen) minLen = len; if (len > maxLen) maxLen = len; }
        return { mode: 'text', count, unique, minLength: minLen, maxLength: maxLen };
      }
      default:
        return { mode: 'mixed', count, unique: new Set(values.map(String)).size };
    }
  }, [selection, results, sortedRows, visibleColumns]);

  // Find in results: compute matches
  const findMatches = useMemo(() => {
    if (!findQuery.trim() || !results || !isFindOpen) return [];
    const query = findQuery.toLowerCase();
    const matches: Array<{ rowIndex: number; colIndex: number }> = [];
    sortedRows.forEach((row, ri) => {
      visibleColumns.forEach((col, ci) => {
        if (formatCellValue(row[col.name], nullDisplay).toLowerCase().includes(query)) {
          matches.push({ rowIndex: ri, colIndex: ci });
        }
      });
    });
    return matches;
  }, [findQuery, sortedRows, visibleColumns, nullDisplay, results, isFindOpen]);

  // Fast lookup set for find highlighting
  const findMatchSet = useMemo(() => {
    const set = new Set<string>();
    findMatches.forEach((m) => set.add(`${m.rowIndex}-${m.colIndex}`));
    return set;
  }, [findMatches]);

  // Reset match index when matches change
  useEffect(() => {
    setCurrentMatchIndex(0);
  }, [findMatches.length]);

  const goToNextMatch = useCallback(() => {
    if (findMatches.length === 0) return;
    setCurrentMatchIndex((prev) => (prev + 1) % findMatches.length);
  }, [findMatches.length]);

  const goToPrevMatch = useCallback(() => {
    if (findMatches.length === 0) return;
    setCurrentMatchIndex((prev) => (prev - 1 + findMatches.length) % findMatches.length);
  }, [findMatches.length]);

  // Inline editing: lookup pending changes by row index
  const pendingEditsByRow = useMemo(() => {
    if (!pendingEdits?.length) return new Map<number, Record<string, unknown>>();
    const map = new Map<number, Record<string, unknown>>();
    for (const edit of pendingEdits) {
      if (edit.type === 'update') {
        const existing = map.get(edit.rowIndex) ?? {};
        map.set(edit.rowIndex, { ...existing, ...edit.changes });
      }
    }
    return map;
  }, [pendingEdits]);

  const deletedRows = useMemo(() => {
    if (!pendingEdits?.length) return new Set<number>();
    return new Set(pendingEdits.filter((e) => e.type === 'delete').map((e) => e.rowIndex));
  }, [pendingEdits]);

  const isEditable = editableInfo?.isEditable ?? false;

  const handleCellDoubleClick = useCallback((rowIndex: number, colIndex: number) => {
    if (!isEditable || !onCellEdit) return;
    const col = visibleColumns[colIndex];
    if (!col) return;
    const row = sortedRows[rowIndex];
    if (!row) return;
    const currentValue = row[col.name];
    setEditingCell({ rowIndex, colIndex });
    setEditValue(currentValue === null ? '' : formatCellValue(currentValue));
    setTimeout(() => editInputRef.current?.focus(), 0);
  }, [isEditable, onCellEdit, visibleColumns, sortedRows]);

  const confirmEdit = useCallback(() => {
    if (!editingCell || !onCellEdit) return;
    const col = visibleColumns[editingCell.colIndex];
    if (!col) return;
    const row = sortedRows[editingCell.rowIndex];
    if (!row) return;
    const oldValue = row[col.name];
    const oldStr = oldValue === null ? '' : formatCellValue(oldValue);
    if (editValue !== oldStr) {
      // Convert empty string back to null for nullable columns
      const newValue = editValue === '' ? null : editValue;
      onCellEdit(editingCell.rowIndex, col.name, newValue);
    }
    setEditingCell(null);
  }, [editingCell, editValue, onCellEdit, visibleColumns, sortedRows]);

  const cancelEdit = useCallback(() => {
    setEditingCell(null);
  }, []);

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
      // Set flag so the click event that fires after mouseup doesn't trigger a sort
      justResizedRef.current = true;
      requestAnimationFrame(() => { justResizedRef.current = false; });
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
    // Focus the wrapper so keyboard events (Escape, Cmd+C, etc.) reach its listener
    wrapperRef.current?.focus();
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
      const value = formatCellValue(row[col.name], nullDisplay);
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

  // Scroll to current find match when it changes
  useEffect(() => {
    if (findMatches.length > 0 && currentMatchIndex < findMatches.length) {
      const match = findMatches[currentMatchIndex];
      rowVirtualizer.scrollToIndex(match.rowIndex, { align: 'center' });
    }
  }, [currentMatchIndex, findMatches, rowVirtualizer]);

  // Reset sort, filters, column visibility, and find when results change (new query executed)
  useEffect(() => {
    setSortColumn(null);
    setSortDirection(null);
    setFilters(new Map());
    setFilterPopoverColumn(null);
    setHiddenColumns(new Set());
    setFindQuery('');
    setIsFindOpen(false);
    setCurrentMatchIndex(0);
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
        results.columns.map((col) => formatCellValue(row[col.name], nullDisplay)).join('\t')
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
      selectedColumns.map(col => formatCellValue(row[col.name], nullDisplay)).join('\t')
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

  // Copy as a specific format (CSV, TSV, Markdown, CTE, SQL INSERT)
  type CopyFormat = 'tsv' | 'csv' | 'markdown' | 'cte' | 'sqlInsert';

  const handleCopyAs = useCallback(async (fmt: CopyFormat) => {
    if (!results) return;

    // Determine columns and rows based on selection
    let columns: { name: string; dataType: string }[];
    let rows: Record<string, unknown>[];
    if (selection) {
      const minRow = Math.min(selection.startRow, selection.endRow);
      const maxRow = Math.max(selection.startRow, selection.endRow);
      const minCol = Math.min(selection.startCol, selection.endCol);
      const maxCol = Math.max(selection.startCol, selection.endCol);
      columns = visibleColumns.slice(minCol, maxCol + 1);
      rows = sortedRows.slice(minRow, maxRow + 1);
    } else {
      columns = results.columns;
      rows = results.rows;
    }

    const escapeCSV = (value: string, delimiter: string): string => {
      if (value.includes(delimiter) || value.includes('"') || value.includes('\n')) {
        return `"${value.replace(/"/g, '""')}"`;
      }
      return value;
    };

    let text: string;
    switch (fmt) {
      case 'tsv': {
        const header = columns.map((c) => c.name).join('\t');
        const dataRows = rows.map((row) =>
          columns.map((col) => formatCellValue(row[col.name], nullDisplay)).join('\t')
        ).join('\n');
        text = `${header}\n${dataRows}`;
        break;
      }
      case 'csv': {
        const header = columns.map((c) => escapeCSV(c.name, ',')).join(',');
        const dataRows = rows.map((row) =>
          columns.map((col) => escapeCSV(formatCellValue(row[col.name], nullDisplay), ',')).join(',')
        ).join('\n');
        text = `${header}\n${dataRows}`;
        break;
      }
      case 'markdown': {
        const headers = columns.map((c) => c.name);
        const headerRow = `| ${headers.join(' | ')} |`;
        const sepRow = `| ${headers.map(() => '---').join(' | ')} |`;
        const dataRows = rows.map((row) => {
          const vals = columns.map((col) =>
            formatCellValue(row[col.name], nullDisplay).replace(/\|/g, '\\|').replace(/\n/g, ' ')
          );
          return `| ${vals.join(' | ')} |`;
        }).join('\n');
        text = `${headerRow}\n${sepRow}\n${dataRows}`;
        break;
      }
      case 'cte': {
        const cteCols = columns.map((c) => `"${c.name.replace(/"/g, '""')}"`).join(', ');
        const cteRows = rows.map((row, rowIdx) => {
          const vals = columns.map((col) => {
            const v = row[col.name];
            const cast = rowIdx === 0 ? `::${col.dataType}` : '';
            if (v === null || v === undefined) return `NULL${cast}`;
            if (typeof v === 'number') return `${v}${cast}`;
            if (typeof v === 'boolean') return `${v}${cast}`;
            return `'${String(v).replace(/'/g, "''")}'${cast}`;
          });
          return `    (${vals.join(', ')})`;
        });
        text = `WITH _cte (${cteCols}) AS (\n  VALUES\n${cteRows.join(',\n')}\n)\nSELECT * FROM _cte;`;
        break;
      }
      case 'sqlInsert': {
        const colList = columns.map((c) => `"${c.name.replace(/"/g, '""')}"`).join(', ');
        text = rows.map((row) => {
          const vals = columns.map((col) => {
            const v = row[col.name];
            if (v === null || v === undefined) return 'NULL';
            if (typeof v === 'number') return String(v);
            if (typeof v === 'boolean') return v ? 'true' : 'false';
            return `'${String(v).replace(/'/g, "''")}'`;
          }).join(', ');
          return `INSERT INTO (${colList}) VALUES (${vals});`;
        }).join('\n');
        break;
      }
    }

    await navigator.clipboard.writeText(text);
    setShowCopyFeedback(true);
    setTimeout(() => setShowCopyFeedback(false), 1500);
  }, [results, selection, visibleColumns, sortedRows, nullDisplay]);

  // Close copy menu on outside click
  useEffect(() => {
    if (!showCopyMenu) return;
    const handleClickOutside = (e: MouseEvent) => {
      if (copyMenuRef.current && !copyMenuRef.current.contains(e.target as Node)) {
        setShowCopyMenu(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [showCopyMenu]);

  // Keyboard handler for Cmd+C, Cmd+F, and Escape — attached to wrapper so it works
  // when any part of the results panel (toolbar, search bar, or grid) has focus
  useEffect(() => {
    const wrapper = wrapperRef.current;
    if (!wrapper) return;

    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'f') {
        e.preventDefault();
        setIsFindOpen(true);
        setTimeout(() => findInputRef.current?.focus(), 0);
      } else if ((e.metaKey || e.ctrlKey) && e.key === 'c' && selection) {
        e.preventDefault();
        handleCopySelection();
      } else if (e.key === 'Escape') {
        e.preventDefault();
        if (editingCell) {
          cancelEdit();
        } else if (isFindOpen) {
          setIsFindOpen(false);
          setFindQuery('');
          setCurrentMatchIndex(0);
        } else if (selection) {
          setSelection(null);
        }
      } else if ((e.key === 'Delete' || e.key === 'Backspace') && isEditable && onDeleteRows && selection && !editingCell) {
        e.preventDefault();
        const minRow = Math.min(selection.startRow, selection.endRow);
        const maxRow = Math.max(selection.startRow, selection.endRow);
        const indices: number[] = [];
        for (let i = minRow; i <= maxRow; i++) {
          if (!deletedRows.has(i)) indices.push(i);
        }
        if (indices.length > 0) onDeleteRows(indices);
      }
    };

    wrapper.addEventListener('keydown', handleKeyDown);
    return () => wrapper.removeEventListener('keydown', handleKeyDown);
  }, [selection, handleCopySelection, isFindOpen, isEditable, onDeleteRows, editingCell, deletedRows, cancelEdit]);

  // Clear selection when clicking header or empty area
  // Handle click on column header (for sorting)
  const handleHeaderClick = useCallback((columnName?: string) => {
    // Ignore click events that fire after a column resize drag
    if (justResizedRef.current) return;

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

  // Expose methods to parent via ref
  useImperativeHandle(ref, () => ({
    copyToClipboard: handleCopyToClipboard,
  }), [handleCopyToClipboard]);

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
    <div ref={wrapperRef} tabIndex={-1} className="h-full w-full flex flex-col overflow-hidden outline-none" style={{ maxWidth: '100%' }}>
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
          {isEditable && (
            <span className="text-[10px] text-green-400 flex items-center gap-1 bg-green-500/10 px-1.5 py-0.5 rounded">
              <Pencil className="w-2.5 h-2.5" />
              Editable
            </span>
          )}
          {editableInfo && !editableInfo.isEditable && (
            <span
              className="text-[11px] text-theme-text-muted flex items-center gap-1 bg-theme-bg-hover px-1.5 py-0.5 rounded cursor-default"
              title={editableInfo.reason ?? 'Results are read-only'}
            >
              <Lock className="w-3 h-3" />
              Read-only
            </span>
          )}
        </div>
        <div className="flex items-center gap-0.5">
          {isEditable && onDeleteRows && selection && (
            <button
              onClick={() => {
                const minRow = Math.min(selection.startRow, selection.endRow);
                const maxRow = Math.max(selection.startRow, selection.endRow);
                const indices: number[] = [];
                for (let i = minRow; i <= maxRow; i++) {
                  if (!deletedRows.has(i)) indices.push(i);
                }
                if (indices.length > 0) onDeleteRows(indices);
              }}
              className="flex items-center gap-1 px-2 py-1 rounded text-[11px] text-red-400 bg-red-500/10 hover:bg-red-500/20 transition-colors"
              title="Delete selected rows (Delete/Backspace)"
            >
              <Trash2 className="w-3 h-3" />
              Delete
            </button>
          )}
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
            onClick={() => {
              setIsFindOpen((prev) => !prev);
              if (!isFindOpen) {
                setTimeout(() => findInputRef.current?.focus(), 0);
              }
            }}
            className={cn(
              'flex items-center gap-1 px-2 py-1 rounded text-[11px] transition-colors',
              isFindOpen
                ? 'text-theme-text-primary bg-theme-bg-active'
                : 'text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover'
            )}
            title="Find in results (Cmd+F)"
          >
            <Search className="w-3 h-3" />
            Find
          </button>
          <div className="relative flex items-center" ref={copyMenuRef}>
            <button
              onClick={handleCopyButtonClick}
              className={cn(
                'flex items-center gap-1 pl-2 pr-1 py-1 rounded-l text-[11px] transition-colors',
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
            <button
              onClick={() => setShowCopyMenu(!showCopyMenu)}
              className={cn(
                'flex items-center px-0.5 py-1 rounded-r text-[11px] transition-colors border-l border-theme-border-primary',
                showCopyMenu
                  ? 'text-theme-text-primary bg-theme-bg-active'
                  : 'text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover'
              )}
              title="Copy as format..."
            >
              <ChevronDown className="w-3 h-3" />
            </button>
            {showCopyMenu && (
              <div className="absolute right-0 top-full mt-1 w-40 rounded-md border border-theme-border-secondary bg-theme-bg-elevated shadow-lg z-50 py-1">
                {([
                  { format: 'csv' as CopyFormat, label: 'CSV' },
                  { format: 'markdown' as CopyFormat, label: 'Markdown' },
                  { format: 'tsv' as CopyFormat, label: 'TSV' },
                  { format: 'cte' as CopyFormat, label: 'CTE' },
                  { format: 'sqlInsert' as CopyFormat, label: 'SQL INSERT' },
                ] as const).map(({ format: fmt, label }) => (
                  <button
                    key={fmt}
                    onClick={() => { handleCopyAs(fmt); setShowCopyMenu(false); }}
                    className="w-full text-left px-3 py-1.5 text-[11px] text-theme-text-secondary hover:bg-theme-bg-hover hover:text-theme-text-primary transition-colors"
                  >
                    {label}
                  </button>
                ))}
              </div>
            )}
          </div>
          <button
            onClick={onExport}
            className="flex items-center gap-1 px-2 py-1 rounded text-[11px] text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover transition-colors"
            title="Export results"
          >
            <Download className="w-3 h-3" />
            Export
          </button>
        </div>
      </div>

      {/* Active filter chips */}
      {filters.size > 0 && (
        <div className="flex items-center gap-1.5 px-3 py-1 border-b border-theme-border-primary flex-shrink-0 flex-wrap">
          <span className="text-[10px] text-theme-text-muted">Filters:</span>
          {Array.from(filters.values()).map((filter) => (
            <span
              key={filter.column}
              className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded bg-blue-500/20 text-blue-700 dark:text-blue-300 text-[10px] font-mono"
            >
              {getFilterLabel(filter)}
              <button
                className="hover:text-blue-900 dark:hover:text-blue-100"
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

      {/* Pending edits bar */}
      {isEditable && pendingEdits && pendingEdits.length > 0 && (
        <div className="flex items-center justify-between px-3 py-1 border-b border-amber-500/30 bg-amber-500/10 flex-shrink-0">
          <span className="text-[11px] text-amber-400 font-medium">
            {pendingEdits.length} pending change{pendingEdits.length !== 1 ? 's' : ''}
          </span>
          <div className="flex items-center gap-1.5">
            <button
              onClick={onDiscardEdits}
              className="px-2 py-0.5 rounded text-[11px] text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
            >
              Discard
            </button>
            <button
              onClick={onCommitEdits}
              className="px-2 py-0.5 rounded text-[11px] text-white bg-amber-600 hover:bg-amber-500 transition-colors"
            >
              Commit
            </button>
          </div>
        </div>
      )}

      {/* Find in results bar */}
      {isFindOpen && (
        <div className="flex items-center gap-2 px-3 py-1 border-b border-theme-border-primary flex-shrink-0 bg-theme-bg-elevated">
          <Search className="w-3.5 h-3.5 text-theme-text-tertiary flex-shrink-0" />
          <input
            ref={findInputRef}
            type="text"
            value={findQuery}
            onChange={(e) => setFindQuery(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') {
                e.preventDefault();
                if (e.shiftKey) {
                  goToPrevMatch();
                } else {
                  goToNextMatch();
                }
              } else if (e.key === 'Escape') {
                e.preventDefault();
                setIsFindOpen(false);
                setFindQuery('');
                setCurrentMatchIndex(0);
                parentRef.current?.focus();
              }
            }}
            placeholder="Find in results..."
            className={cn(
              'flex-1 min-w-0 px-2 py-0.5 rounded text-xs',
              'bg-theme-bg-surface border border-theme-border-primary',
              'text-theme-text-primary placeholder-theme-text-muted',
              'focus:outline-none focus:border-theme-border-secondary'
            )}
          />
          <span className="text-[10px] text-theme-text-muted whitespace-nowrap">
            {findQuery.trim()
              ? findMatches.length > 0
                ? `${currentMatchIndex + 1} of ${findMatches.length}`
                : 'No matches'
              : ''}
          </span>
          <button
            onClick={goToPrevMatch}
            disabled={findMatches.length === 0}
            className="p-0.5 rounded hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
            title="Previous match (Shift+Enter)"
          >
            <ChevronUp className="w-3.5 h-3.5" />
          </button>
          <button
            onClick={goToNextMatch}
            disabled={findMatches.length === 0}
            className="p-0.5 rounded hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
            title="Next match (Enter)"
          >
            <ChevronDown className="w-3.5 h-3.5" />
          </button>
          <button
            onClick={() => {
              setIsFindOpen(false);
              setFindQuery('');
              setCurrentMatchIndex(0);
              parentRef.current?.focus();
            }}
            className="p-0.5 rounded hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary transition-colors"
            title="Close (Escape)"
          >
            <X className="w-3.5 h-3.5" />
          </button>
        </div>
      )}

      {/* Table - scrollable area */}
      <div className="flex-1 min-h-0 overflow-hidden">
        <div ref={parentRef} className="h-full overflow-auto outline-none" tabIndex={0} onClick={handleContainerClick}>
          {/* Inner container - sets the scrollable width */}
          <div style={{ width: Math.max(totalTableWidth, 1), minWidth: totalTableWidth, fontSize: `${resultsFontSize}px` }} onClick={handleContainerClick}>
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
                        className="px-1 py-0.5 text-[11px] font-mono text-theme-text-muted border-b border-r border-theme-border-primary flex-shrink-0 text-right select-none cursor-pointer hover:bg-theme-bg-active hover:text-theme-text-secondary"
                        style={{ width: ROW_NUMBER_WIDTH, minWidth: ROW_NUMBER_WIDTH }}
                        onMouseDown={(e) => {
                          e.preventDefault();
                          const rowIdx = virtualRow.index;
                          const lastCol = visibleColumns.length - 1;
                          if (e.shiftKey && selection) {
                            // Extend selection from anchor row to clicked row, full width
                            setSelection({
                              startRow: selection.startRow,
                              startCol: 0,
                              endRow: rowIdx,
                              endCol: lastCol,
                            });
                          } else {
                            setSelection({
                              startRow: rowIdx,
                              startCol: 0,
                              endRow: rowIdx,
                              endCol: lastCol,
                            });
                          }
                          wrapperRef.current?.focus();
                        }}
                      >
                        {virtualRow.index + 1}
                      </div>
                    )}
                    {visibleColumns.map((col, colIndex) => {
                      const isFindMatch = findMatchSet.has(`${virtualRow.index}-${colIndex}`);
                      const isCurrentFindMatch = isFindMatch && findMatches.length > 0 && findMatches[currentMatchIndex]?.rowIndex === virtualRow.index && findMatches[currentMatchIndex]?.colIndex === colIndex;
                      const isEditingThis = editingCell?.rowIndex === virtualRow.index && editingCell?.colIndex === colIndex;
                      const pendingChanges = pendingEditsByRow.get(virtualRow.index);
                      const hasPendingChange = pendingChanges != null && col.name in pendingChanges;
                      const isRowDeleted = deletedRows.has(virtualRow.index);
                      return (
                      <div
                        key={col.name}
                        className={cn(
                          'px-2 py-0.5 text-[11px] font-mono border-b border-r border-theme-border-primary flex-shrink-0 text-left overflow-hidden cursor-cell select-none relative',
                          wrapText ? 'break-words' : 'text-ellipsis',
                          wrapText || showNewlines ? 'whitespace-pre-wrap' : 'whitespace-nowrap',
                          getCellClassName(row[col.name]),
                          isCellSelected(virtualRow.index, colIndex) && 'bg-blue-500/20 outline outline-1 -outline-offset-1 outline-blue-500/50',
                          isFindMatch && !isCurrentFindMatch && 'bg-amber-500/20',
                          isCurrentFindMatch && 'bg-amber-500/40 ring-1 ring-amber-500 -outline-offset-1',
                          hasPendingChange && 'border-l-2 border-l-amber-500',
                          isRowDeleted && 'line-through opacity-50 border-l-2 border-l-red-500'
                        )}
                        style={{ width: effectiveColumnWidths[col.name], minWidth: effectiveColumnWidths[col.name] }}
                        title={formatCellValue(row[col.name], nullDisplay)}
                        onMouseDown={(e) => handleCellMouseDown(virtualRow.index, colIndex, e)}
                        onMouseEnter={() => handleCellMouseEnter(virtualRow.index, colIndex)}
                        onDoubleClick={() => handleCellDoubleClick(virtualRow.index, colIndex)}
                      >
                        {isEditingThis ? (
                          <input
                            ref={editInputRef}
                            type="text"
                            value={editValue}
                            onChange={(e) => setEditValue(e.target.value)}
                            onKeyDown={(e) => {
                              if (e.key === 'Enter' || e.key === 'Tab') {
                                e.preventDefault();
                                confirmEdit();
                              } else if (e.key === 'Escape') {
                                e.preventDefault();
                                cancelEdit();
                              }
                            }}
                            onBlur={confirmEdit}
                            className="w-full h-full bg-theme-bg-surface text-theme-text-primary text-[11px] font-mono border-none outline-none ring-1 ring-blue-500 px-1 -mx-1"
                          />
                        ) : (
                          getDisplayValue(row[col.name], showNewlines, nullDisplay)
                        )}
                      </div>
                      );
                    })}
                  </div>
                );
              })}
            </div>

          </div>
        </div>
      </div>

      {/* Load More bar — outside the scrollable table so it stays fixed and centered */}
      {results.hasMore && (
        <div className="flex items-center justify-center py-1.5 border-t border-theme-border-primary flex-shrink-0 bg-theme-bg-elevated">
          {isLoadingMore ? (
            <div className="flex items-center gap-2 text-xs text-theme-text-muted">
              <div className="w-3 h-3 border-2 border-theme-text-muted border-t-theme-text-secondary rounded-full animate-spin" />
              Loading more rows...
            </div>
          ) : (
            <button
              onClick={onLoadMore}
              className="px-4 py-1 rounded text-[11px] text-theme-text-secondary bg-theme-bg-hover hover:bg-theme-bg-active transition-colors"
            >
              Load more rows
            </button>
          )}
        </div>
      )}

      {/* Aggregate footer */}
      {aggregates && (
        <div className="flex items-center gap-4 px-3 py-1 border-t border-theme-border-primary flex-shrink-0 text-[11px] text-theme-text-secondary font-mono">
          <span>Count: {aggregates.count.toLocaleString()}</span>
          {aggregates.mode === 'numeric' && (
            <>
              <span>Sum: {aggregates.sum.toLocaleString(undefined, { maximumFractionDigits: 4 })}</span>
              <span>Avg: {aggregates.avg.toLocaleString(undefined, { maximumFractionDigits: 4 })}</span>
              <span>Min: {aggregates.min.toLocaleString(undefined, { maximumFractionDigits: 4 })}</span>
              <span>Max: {aggregates.max.toLocaleString(undefined, { maximumFractionDigits: 4 })}</span>
            </>
          )}
          {aggregates.mode === 'temporal' && (
            <>
              <span>Duration: {aggregates.duration}</span>
              <span>Earliest: {aggregates.min}</span>
              <span>Latest: {aggregates.max}</span>
            </>
          )}
          {aggregates.mode === 'ip' && (
            <>
              <span>Unique: {aggregates.unique.toLocaleString()}</span>
              <span>Min: {aggregates.min}</span>
              <span>Max: {aggregates.max}</span>
            </>
          )}
          {aggregates.mode === 'boolean' && (
            <>
              <span>True: {aggregates.trueCount.toLocaleString()}</span>
              <span>False: {aggregates.falseCount.toLocaleString()}</span>
            </>
          )}
          {aggregates.mode === 'text' && (
            <>
              <span>Unique: {aggregates.unique.toLocaleString()}</span>
              <span>Shortest: {aggregates.minLength}</span>
              <span>Longest: {aggregates.maxLength}</span>
            </>
          )}
          {aggregates.mode === 'mixed' && (
            <span>Unique: {aggregates.unique.toLocaleString()}</span>
          )}
        </div>
      )}
    </div>
  );
});
