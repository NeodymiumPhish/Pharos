import { useRef, useMemo, useCallback, useState, useEffect, forwardRef, useImperativeHandle } from 'react';
import { useVirtualizer } from '@tanstack/react-virtual';
import { Download, Copy, AlertCircle, WrapText, AlignLeft, Pin, PinOff } from 'lucide-react';
import { cn } from '@/lib/cn';
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
}

// Constants for column width calculation
const MIN_COLUMN_WIDTH = 60;
const MAX_COLUMN_WIDTH = 500;
const DEFAULT_COLUMN_WIDTH = 150;
const CHAR_WIDTH = 7.5; // Approximate width of a monospace character
const COLUMN_PADDING = 32; // px for padding on both sides
const SAMPLE_ROWS = 100; // Number of rows to sample for width calculation

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

export const ResultsGrid = forwardRef<ResultsGridRef, ResultsGridProps>(function ResultsGrid(
  { results, error, executionTime, isExecuting, isPinned, pinnedTabName, canPin, onPin, onUnpin },
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

  // Calculate total table width
  const totalTableWidth = useMemo(() => {
    if (!results) return 0;
    return results.columns.reduce((sum, col) => sum + (effectiveColumnWidths[col.name] ?? DEFAULT_COLUMN_WIDTH), 0);
  }, [results, effectiveColumnWidths]);

  // Handle column resize
  const handleColumnResizeStart = useCallback((e: React.MouseEvent, columnName: string) => {
    e.preventDefault();
    e.stopPropagation();
    setResizingColumn(columnName);

    const startX = e.clientX;
    const startWidth = effectiveColumnWidths[columnName] ?? DEFAULT_COLUMN_WIDTH;

    const handleMouseMove = (moveEvent: MouseEvent) => {
      const delta = moveEvent.clientX - startX;
      const newWidth = Math.max(MIN_COLUMN_WIDTH, Math.min(MAX_COLUMN_WIDTH, startWidth + delta));
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

    const row = results.rows[index];
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
  }, [showNewlines, wrapText, results, effectiveColumnWidths]);

  const rowVirtualizer = useVirtualizer({
    count: results?.rows.length ?? 0,
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
  }, [results]);

  // Copy only selected cells with their column headers
  const handleCopySelection = useCallback(async () => {
    if (!results || !selection) return;

    const minRow = Math.min(selection.startRow, selection.endRow);
    const maxRow = Math.max(selection.startRow, selection.endRow);
    const minCol = Math.min(selection.startCol, selection.endCol);
    const maxCol = Math.max(selection.startCol, selection.endCol);

    // Get selected columns
    const selectedColumns = results.columns.slice(minCol, maxCol + 1);

    // Header row
    const header = selectedColumns.map(c => c.name).join('\t');

    // Data rows
    const rows = results.rows.slice(minRow, maxRow + 1).map(row =>
      selectedColumns.map(col => formatCellValue(row[col.name])).join('\t')
    ).join('\n');

    await navigator.clipboard.writeText(`${header}\n${rows}`);
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
  const handleHeaderClick = useCallback(() => {
    setSelection(null);
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

  const handleExportCSV = useCallback(() => {
    if (!results) return;

    const escapeCSV = (value: string): string => {
      if (value.includes(',') || value.includes('"') || value.includes('\n')) {
        return `"${value.replace(/"/g, '""')}"`;
      }
      return value;
    };

    const header = results.columns.map((c) => escapeCSV(c.name)).join(',');
    const rows = results.rows
      .map((row) =>
        results.columns
          .map((col) => escapeCSV(formatCellValue(row[col.name])))
          .join(',')
      )
      .join('\n');

    const csv = `${header}\n${rows}`;
    const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = `query_results_${Date.now()}.csv`;
    link.click();
    URL.revokeObjectURL(url);
  }, [results]);

  // Expose methods to parent via ref
  useImperativeHandle(ref, () => ({
    copyToClipboard: handleCopyToClipboard,
    exportCSV: handleExportCSV,
  }), [handleCopyToClipboard, handleExportCSV]);

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
            0 rows {executionTime !== null && `(${executionTime}ms)`}
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
          <span className="text-xs text-theme-text-secondary">
            {results.rowCount.toLocaleString()} row{results.rowCount !== 1 ? 's' : ''}
            {results.hasMore && '+'}
            {executionTime !== null && (
              <span className="text-theme-text-tertiary ml-1.5">({executionTime}ms)</span>
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
            className="flex items-center gap-1 px-2 py-1 rounded text-[11px] text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover transition-colors"
            title={selection ? "Copy selected cells" : "Copy all to clipboard"}
          >
            <Copy className="w-3 h-3" />
            {selection ? 'Copy Selection' : 'Copy'}
          </button>
          <button
            onClick={handleExportCSV}
            className="flex items-center gap-1 px-2 py-1 rounded text-[11px] text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover transition-colors"
            title="Export as CSV"
          >
            <Download className="w-3 h-3" />
            CSV
          </button>
        </div>
      </div>

      {/* Table - scrollable area */}
      <div className="flex-1 min-h-0 overflow-hidden">
        <div ref={parentRef} className="h-full overflow-auto outline-none" tabIndex={0} onClick={handleContainerClick}>
          {/* Inner container - sets the scrollable width */}
          <div style={{ width: Math.max(totalTableWidth, 1), minWidth: totalTableWidth }} onClick={handleContainerClick}>
            {/* Header row - sticky */}
            <div
              className="sticky top-0 z-10 bg-theme-bg-elevated flex border-b border-theme-border-primary"
              style={{ width: totalTableWidth }}
              onClick={handleHeaderClick}
            >
              {results.columns.map((col) => (
                <div
                  key={col.name}
                  className="relative px-2 py-1 text-left text-[11px] font-medium text-theme-text-secondary border-r border-theme-border-primary whitespace-nowrap flex-shrink-0 group cursor-default"
                  style={{ width: effectiveColumnWidths[col.name], minWidth: effectiveColumnWidths[col.name] }}
                >
                  <div className="flex items-center gap-1.5">
                    <span className="truncate">{col.name}</span>
                    <span className="text-theme-text-tertiary font-normal text-[10px]">{col.dataType}</span>
                  </div>
                  {/* Resize handle */}
                  <div
                    className={cn(
                      'absolute right-0 top-0 bottom-0 w-1 cursor-col-resize transition-colors',
                      'hover:bg-blue-500/50',
                      resizingColumn === col.name && 'bg-blue-500'
                    )}
                    onMouseDown={(e) => handleColumnResizeStart(e, col.name)}
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
                const row = results.rows[virtualRow.index];
                return (
                  <div
                    key={virtualRow.key}
                    className="flex hover:bg-theme-bg-hover"
                    style={{
                      position: 'absolute',
                      top: 0,
                      left: 0,
                      width: totalTableWidth,
                      height: `${virtualRow.size}px`,
                      transform: `translateY(${virtualRow.start}px)`,
                    }}
                  >
                    {results.columns.map((col, colIndex) => (
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
          </div>
        </div>
      </div>
    </div>
  );
});
