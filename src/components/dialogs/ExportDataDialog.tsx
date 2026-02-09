import { useState, useCallback, useEffect } from 'react';
import { X, Download, Loader2, CheckSquare, Square } from 'lucide-react';
import { save } from '@tauri-apps/plugin-dialog';
import { cn } from '@/lib/cn';
import * as tauri from '@/lib/tauri';
import type { ColumnInfo, ExportFormat } from '@/lib/types';

const FORMAT_OPTIONS: { value: ExportFormat; label: string; ext: string; filterName: string }[] = [
  { value: 'csv', label: 'CSV', ext: 'csv', filterName: 'CSV Files' },
  { value: 'tsv', label: 'TSV', ext: 'tsv', filterName: 'TSV Files' },
  { value: 'json', label: 'JSON', ext: 'json', filterName: 'JSON Files' },
  { value: 'jsonLines', label: 'JSON Lines', ext: 'jsonl', filterName: 'JSON Lines Files' },
  { value: 'sqlInsert', label: 'SQL INSERT', ext: 'sql', filterName: 'SQL Files' },
  { value: 'markdown', label: 'Markdown', ext: 'md', filterName: 'Markdown Files' },
  { value: 'xlsx', label: 'Excel (XLSX)', ext: 'xlsx', filterName: 'Excel Files' },
];

interface ExportDataDialogProps {
  isOpen: boolean;
  onClose: () => void;
  connectionId: string;
  schema: string;
  table: string;
  type: 'table' | 'view' | 'foreign-table';
}

export function ExportDataDialog({
  isOpen,
  onClose,
  connectionId,
  schema,
  table,
  type,
}: ExportDataDialogProps) {
  const [columns, setColumns] = useState<ColumnInfo[]>([]);
  const [selectedColumns, setSelectedColumns] = useState<Set<string>>(new Set());
  const [format, setFormat] = useState<ExportFormat>('csv');
  const [includeHeaders, setIncludeHeaders] = useState(true);
  const [nullAsEmpty, setNullAsEmpty] = useState(true);
  const [isLoading, setIsLoading] = useState(false);
  const [isExporting, setIsExporting] = useState(false);
  const [result, setResult] = useState<{ success: boolean; message: string } | null>(null);

  // Load columns when dialog opens
  useEffect(() => {
    if (isOpen) {
      setResult(null);
      setIsLoading(true);

      tauri.getColumns(connectionId, schema, table)
        .then((cols) => {
          setColumns(cols);
          setSelectedColumns(new Set(cols.map(c => c.name)));
        })
        .catch((err) => {
          console.error('Failed to load columns:', err);
          setColumns([]);
          setSelectedColumns(new Set());
        })
        .finally(() => {
          setIsLoading(false);
        });
    }
  }, [isOpen, connectionId, schema, table]);

  const toggleColumn = useCallback((columnName: string) => {
    setSelectedColumns((prev) => {
      const next = new Set(prev);
      if (next.has(columnName)) {
        next.delete(columnName);
      } else {
        next.add(columnName);
      }
      return next;
    });
  }, []);

  const selectAll = useCallback(() => {
    setSelectedColumns(new Set(columns.map(c => c.name)));
  }, [columns]);

  const deselectAll = useCallback(() => {
    setSelectedColumns(new Set());
  }, []);

  const handleExport = useCallback(async () => {
    if (selectedColumns.size === 0) {
      setResult({ success: false, message: 'Please select at least one column' });
      return;
    }

    const formatOpt = FORMAT_OPTIONS.find(f => f.value === format)!;

    // Open save dialog
    const savePath = await save({
      defaultPath: `${table}.${formatOpt.ext}`,
      filters: [{ name: formatOpt.filterName, extensions: [formatOpt.ext] }],
    });

    if (!savePath) return;

    setIsExporting(true);
    setResult(null);

    try {
      const exportResult = await tauri.exportTable(connectionId, {
        schemaName: schema,
        tableName: table,
        columns: Array.from(selectedColumns),
        includeHeaders,
        nullAsEmpty,
        filePath: savePath,
        format,
      });

      if (exportResult.success) {
        setResult({
          success: true,
          message: `Successfully exported ${exportResult.rowsExported} rows!`,
        });

        // Close after short delay
        setTimeout(() => {
          onClose();
        }, 1500);
      }
    } catch (err) {
      setResult({
        success: false,
        message: err instanceof Error ? err.message : String(err),
      });
    } finally {
      setIsExporting(false);
    }
  }, [connectionId, schema, table, selectedColumns, includeHeaders, nullAsEmpty, format, onClose]);

  if (!isOpen) return null;

  const allSelected = selectedColumns.size === columns.length;
  const noneSelected = selectedColumns.size === 0;

  // Headers don't apply to JSON/SQL INSERT formats
  const showHeadersOption = !['json', 'jsonLines', 'sqlInsert'].includes(format);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* Backdrop */}
      <div className="absolute inset-0 bg-black/50" onClick={onClose} />

      {/* Dialog */}
      <div className="relative w-full max-w-md mx-4 rounded-lg border border-theme-border-secondary bg-theme-bg-elevated shadow-2xl max-h-[80vh] flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b border-theme-border-primary flex-shrink-0">
          <div className="flex items-center gap-2">
            <Download className="w-5 h-5 text-purple-400" />
            <h2 className="text-lg font-semibold text-theme-text-primary">Export Data</h2>
          </div>
          <button
            onClick={onClose}
            className="p-1 rounded hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Content */}
        <div className="p-4 space-y-4 overflow-y-auto flex-1">
          {/* Source info */}
          <div className="text-sm text-theme-text-secondary">
            Export from: <span className="font-mono text-theme-text-primary">{schema}.{table}</span>
            {type === 'view' && <span className="ml-2 text-cyan-400">(view)</span>}
            {type === 'foreign-table' && <span className="ml-2 text-orange-400">(foreign table)</span>}
          </div>

          {/* Format selector */}
          <div>
            <label className="text-sm text-theme-text-secondary mb-1.5 block">Format</label>
            <div className="flex flex-wrap gap-1.5">
              {FORMAT_OPTIONS.map((opt) => (
                <button
                  key={opt.value}
                  onClick={() => setFormat(opt.value)}
                  className={cn(
                    'px-2.5 py-1 rounded text-xs font-medium transition-colors',
                    format === opt.value
                      ? 'bg-purple-600 text-white'
                      : 'bg-theme-bg-surface text-theme-text-secondary hover:bg-theme-bg-hover border border-theme-border-primary'
                  )}
                >
                  {opt.label}
                </button>
              ))}
            </div>
          </div>

          {/* Column selection */}
          <div>
            <div className="flex items-center justify-between mb-2">
              <label className="text-sm text-theme-text-secondary">Columns</label>
              <div className="flex gap-2">
                <button
                  onClick={selectAll}
                  disabled={allSelected}
                  className="text-xs text-blue-400 hover:text-blue-300 disabled:text-theme-text-muted"
                >
                  Select All
                </button>
                <span className="text-theme-text-muted">|</span>
                <button
                  onClick={deselectAll}
                  disabled={noneSelected}
                  className="text-xs text-blue-400 hover:text-blue-300 disabled:text-theme-text-muted"
                >
                  Deselect All
                </button>
              </div>
            </div>

            {isLoading ? (
              <div className="flex items-center gap-2 text-sm text-theme-text-secondary py-4">
                <Loader2 className="w-4 h-4 animate-spin" />
                Loading columns...
              </div>
            ) : (
              <div className="max-h-48 overflow-y-auto border border-theme-border-primary rounded bg-theme-bg-surface">
                {columns.map((col) => (
                  <button
                    key={col.name}
                    onClick={() => toggleColumn(col.name)}
                    className="w-full flex items-center gap-2 px-2 py-1.5 hover:bg-theme-bg-hover text-left"
                  >
                    {selectedColumns.has(col.name) ? (
                      <CheckSquare className="w-4 h-4 text-blue-400 flex-shrink-0" />
                    ) : (
                      <Square className="w-4 h-4 text-theme-text-muted flex-shrink-0" />
                    )}
                    <span className="text-sm text-theme-text-primary truncate">{col.name}</span>
                    <span className="text-xs text-theme-text-tertiary font-mono ml-auto flex-shrink-0">
                      {col.dataType}
                    </span>
                  </button>
                ))}
              </div>
            )}
          </div>

          {/* Export options */}
          <div className="space-y-2">
            {showHeadersOption && (
              <label className="flex items-center gap-2 cursor-pointer">
                <input
                  type="checkbox"
                  checked={includeHeaders}
                  onChange={(e) => setIncludeHeaders(e.target.checked)}
                  className="w-4 h-4 rounded"
                />
                <span className="text-sm text-theme-text-secondary">Include headers</span>
              </label>
            )}
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                checked={nullAsEmpty}
                onChange={(e) => setNullAsEmpty(e.target.checked)}
                className="w-4 h-4 rounded"
              />
              <span className="text-sm text-theme-text-secondary">Show NULL as empty string</span>
            </label>
          </div>

          {/* Result message */}
          {result && (
            <div
              className={cn(
                'p-3 rounded text-sm',
                result.success
                  ? 'bg-green-500/20 text-green-700 dark:text-green-300 border border-green-500/30'
                  : 'bg-red-500/20 text-red-700 dark:text-red-300 border border-red-500/30'
              )}
            >
              {result.message}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-end gap-2 p-4 border-t border-theme-border-primary flex-shrink-0">
          <button
            onClick={onClose}
            disabled={isExporting}
            className="px-4 py-2 rounded bg-theme-bg-hover hover:bg-theme-bg-active text-theme-text-secondary disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            onClick={handleExport}
            disabled={isExporting || selectedColumns.size === 0}
            className="px-4 py-2 rounded bg-purple-600 hover:bg-purple-500 text-white disabled:opacity-50 flex items-center gap-2"
          >
            {isExporting && <Loader2 className="w-4 h-4 animate-spin" />}
            Export
          </button>
        </div>
      </div>
    </div>
  );
}
