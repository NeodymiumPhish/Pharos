import { useState, useCallback, useEffect, useRef } from 'react';
import { X, Download, Loader2 } from 'lucide-react';
import { save } from '@tauri-apps/plugin-dialog';
import { listen } from '@tauri-apps/api/event';
import { cn } from '@/lib/cn';
import * as tauri from '@/lib/tauri';
import type { ExportFormat, ExportProgress } from '@/lib/types';
import type { QueryResults } from '@/stores/editorStore';

const FORMAT_OPTIONS: { value: ExportFormat; label: string; ext: string; filterName: string }[] = [
  { value: 'csv', label: 'CSV', ext: 'csv', filterName: 'CSV Files' },
  { value: 'tsv', label: 'TSV', ext: 'tsv', filterName: 'TSV Files' },
  { value: 'json', label: 'JSON', ext: 'json', filterName: 'JSON Files' },
  { value: 'jsonLines', label: 'JSON Lines', ext: 'jsonl', filterName: 'JSON Lines Files' },
  { value: 'sqlInsert', label: 'SQL INSERT', ext: 'sql', filterName: 'SQL Files' },
  { value: 'markdown', label: 'Markdown', ext: 'md', filterName: 'Markdown Files' },
  { value: 'xlsx', label: 'Excel (XLSX)', ext: 'xlsx', filterName: 'Excel Files' },
];

function formatCellValue(value: unknown, nullDisplay: string = 'NULL'): string {
  if (value === null) return nullDisplay;
  if (value === undefined) return '';
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'object') return JSON.stringify(value);
  return String(value);
}

interface ExportResultsDialogProps {
  isOpen: boolean;
  onClose: () => void;
  connectionId: string;
  sql: string;
  schema: string | null;
  results: QueryResults | null;
}

export function ExportResultsDialog({
  isOpen,
  onClose,
  connectionId,
  sql,
  schema,
  results,
}: ExportResultsDialogProps) {
  const [format, setFormat] = useState<ExportFormat>('csv');
  const [rowScope, setRowScope] = useState<'current' | 'all'>('current');
  const [isExporting, setIsExporting] = useState(false);
  const [progress, setProgress] = useState<ExportProgress | null>(null);
  const [result, setResult] = useState<{ success: boolean; message: string } | null>(null);
  const unlistenRef = useRef<(() => void) | null>(null);

  // Reset state when dialog opens
  useEffect(() => {
    if (isOpen) {
      setResult(null);
      setProgress(null);
      setRowScope('current');
      setIsExporting(false);
    }
    return () => {
      if (unlistenRef.current) {
        unlistenRef.current();
        unlistenRef.current = null;
      }
    };
  }, [isOpen]);

  const generateTextExport = useCallback((fmt: ExportFormat): string | null => {
    if (!results) return null;
    const escapeCSV = (value: string, delimiter: string): string => {
      if (value.includes(delimiter) || value.includes('"') || value.includes('\n')) {
        return `"${value.replace(/"/g, '""')}"`;
      }
      return value;
    };

    switch (fmt) {
      case 'csv':
      case 'tsv': {
        const delim = fmt === 'tsv' ? '\t' : ',';
        const header = results.columns.map((c) => escapeCSV(c.name, delim)).join(delim);
        const rows = results.rows
          .map((row) =>
            results.columns.map((col) => escapeCSV(formatCellValue(row[col.name]), delim)).join(delim)
          )
          .join('\n');
        return `${header}\n${rows}`;
      }
      case 'json': {
        const jsonRows = results.rows.map((row) => {
          const obj: Record<string, unknown> = {};
          results.columns.forEach((col) => { obj[col.name] = row[col.name] ?? null; });
          return obj;
        });
        return JSON.stringify(jsonRows, null, 2);
      }
      case 'jsonLines': {
        return results.rows.map((row) => {
          const obj: Record<string, unknown> = {};
          results.columns.forEach((col) => { obj[col.name] = row[col.name] ?? null; });
          return JSON.stringify(obj);
        }).join('\n');
      }
      case 'sqlInsert': {
        const colList = results.columns.map((c) => `"${c.name.replace(/"/g, '""')}"`).join(', ');
        return results.rows.map((row) => {
          const vals = results.columns.map((col) => {
            const v = row[col.name];
            if (v === null || v === undefined) return 'NULL';
            if (typeof v === 'number') return String(v);
            if (typeof v === 'boolean') return v ? 'true' : 'false';
            return `'${String(v).replace(/'/g, "''")}'`;
          }).join(', ');
          return `INSERT INTO (${colList}) VALUES (${vals});`;
        }).join('\n');
      }
      case 'markdown': {
        const headers = results.columns.map((c) => c.name);
        const headerRow = `| ${headers.join(' | ')} |`;
        const sepRow = `| ${headers.map(() => '---').join(' | ')} |`;
        const dataRows = results.rows.map((row) => {
          const vals = results.columns.map((col) =>
            formatCellValue(row[col.name]).replace(/\|/g, '\\|').replace(/\n/g, ' ')
          );
          return `| ${vals.join(' | ')} |`;
        }).join('\n');
        return `${headerRow}\n${sepRow}\n${dataRows}`;
      }
      default:
        return null;
    }
  }, [results]);

  const handleExport = useCallback(async () => {
    if (!results) return;
    const formatOpt = FORMAT_OPTIONS.find(f => f.value === format)!;

    const savePath = await save({
      defaultPath: `query_results.${formatOpt.ext}`,
      filters: [{ name: formatOpt.filterName, extensions: [formatOpt.ext] }],
    });
    if (!savePath) return;

    setIsExporting(true);
    setResult(null);
    setProgress(null);

    try {
      if (rowScope === 'all') {
        // Listen for progress events
        const unlisten = await listen<ExportProgress>('export-progress', (event) => {
          setProgress(event.payload);
        });
        unlistenRef.current = unlisten;

        const exportResult = await tauri.exportQuery(connectionId, {
          sql,
          schema,
          filePath: savePath,
          format,
        });

        if (unlistenRef.current) {
          unlistenRef.current();
          unlistenRef.current = null;
        }

        if (exportResult.success) {
          setResult({
            success: true,
            message: `Exported ${exportResult.rowsExported.toLocaleString()} rows`,
          });
          setTimeout(onClose, 1500);
        }
      } else {
        // Current rows export
        if (format === 'xlsx') {
          await tauri.exportResults({
            columns: results.columns.map((c) => ({ name: c.name, dataType: c.dataType })),
            rows: results.rows,
            filePath: savePath,
          });
        } else {
          const content = generateTextExport(format);
          if (!content) throw new Error('Failed to generate export content');
          await tauri.writeTextExport(savePath, content);
        }
        setResult({
          success: true,
          message: `Exported ${results.rows.length.toLocaleString()} rows`,
        });
        setTimeout(onClose, 1500);
      }
    } catch (err) {
      if (unlistenRef.current) {
        unlistenRef.current();
        unlistenRef.current = null;
      }
      setResult({
        success: false,
        message: err instanceof Error ? err.message : String(err),
      });
    } finally {
      setIsExporting(false);
    }
  }, [format, rowScope, connectionId, sql, schema, results, generateTextExport, onClose]);

  if (!isOpen || !results) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div className="absolute inset-0 bg-black/50" onClick={!isExporting ? onClose : undefined} />

      <div className="relative w-full max-w-md mx-4 rounded-2xl border border-theme-border-secondary bg-theme-bg-elevated shadow-2xl backdrop-blur-xl flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b border-theme-border-primary flex-shrink-0">
          <div className="flex items-center gap-2">
            <Download className="w-5 h-5 text-purple-400" />
            <h2 className="text-lg font-semibold text-theme-text-primary">Export Results</h2>
          </div>
          <button
            onClick={onClose}
            disabled={isExporting}
            className="p-1 rounded hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary disabled:opacity-50"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Content */}
        <div className="p-4 space-y-4">
          {/* Format selector */}
          <div>
            <label className="text-sm text-theme-text-secondary mb-1.5 block">Format</label>
            <div className="flex flex-wrap gap-1.5">
              {FORMAT_OPTIONS.map((opt) => (
                <button
                  key={opt.value}
                  onClick={() => setFormat(opt.value)}
                  disabled={isExporting}
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

          {/* Row scope - only shown when more rows available */}
          {results.hasMore && (
            <div>
              <label className="text-sm text-theme-text-secondary mb-1.5 block">Rows to export</label>
              <div className="space-y-1.5">
                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="radio"
                    name="rowScope"
                    checked={rowScope === 'current'}
                    onChange={() => setRowScope('current')}
                    disabled={isExporting}
                    className="w-4 h-4"
                  />
                  <span className="text-sm text-theme-text-secondary">
                    Current rows ({results.rows.length.toLocaleString()} loaded)
                  </span>
                </label>
                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="radio"
                    name="rowScope"
                    checked={rowScope === 'all'}
                    onChange={() => setRowScope('all')}
                    disabled={isExporting}
                    className="w-4 h-4"
                  />
                  <span className="text-sm text-theme-text-secondary">
                    All rows (fetch from database)
                  </span>
                </label>
              </div>
            </div>
          )}

          {/* Progress bar */}
          {isExporting && rowScope === 'all' && (
            <div className="space-y-1.5">
              <div className="h-2 rounded-full bg-theme-bg-surface overflow-hidden">
                <div
                  className="h-full bg-purple-500 rounded-full transition-all duration-300 animate-pulse"
                  style={{ width: progress ? '100%' : '30%' }}
                />
              </div>
              <div className="text-xs text-theme-text-muted">
                {progress
                  ? `${progress.rowsExported.toLocaleString()} rows exported...`
                  : 'Starting export...'}
              </div>
            </div>
          )}

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
            disabled={isExporting}
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
