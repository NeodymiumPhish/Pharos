import { useState, useCallback, useEffect } from 'react';
import { X, Upload, Loader2, FileText, CheckCircle, XCircle } from 'lucide-react';
import { open } from '@tauri-apps/plugin-dialog';
import { cn } from '@/lib/cn';
import * as tauri from '@/lib/tauri';
import type { CsvValidationResult } from '@/lib/types';

interface ImportDataDialogProps {
  isOpen: boolean;
  onClose: () => void;
  connectionId: string;
  schema: string;
  table: string;
  onSuccess: () => void;
}

export function ImportDataDialog({
  isOpen,
  onClose,
  connectionId,
  schema,
  table,
  onSuccess,
}: ImportDataDialogProps) {
  const [filePath, setFilePath] = useState<string | null>(null);
  const [hasHeaders, setHasHeaders] = useState(true);
  const [validation, setValidation] = useState<CsvValidationResult | null>(null);
  const [isValidating, setIsValidating] = useState(false);
  const [isImporting, setIsImporting] = useState(false);
  const [result, setResult] = useState<{ success: boolean; message: string } | null>(null);

  // Reset form when dialog opens
  useEffect(() => {
    if (isOpen) {
      setFilePath(null);
      setValidation(null);
      setResult(null);
      setHasHeaders(true);
    }
  }, [isOpen]);

  const handleSelectFile = useCallback(async () => {
    const selected = await open({
      multiple: false,
      filters: [{ name: 'CSV Files', extensions: ['csv'] }],
    });

    if (selected && typeof selected === 'string') {
      setFilePath(selected);
      setValidation(null);
      setResult(null);
    }
  }, []);

  const handleValidate = useCallback(async () => {
    if (!filePath) return;

    setIsValidating(true);
    setValidation(null);
    setResult(null);

    try {
      const validationResult = await tauri.validateCsvForImport(
        connectionId,
        schema,
        table,
        filePath,
        hasHeaders
      );
      setValidation(validationResult);
    } catch (err) {
      setResult({
        success: false,
        message: err instanceof Error ? err.message : typeof err === 'string' ? err : 'Validation failed',
      });
    } finally {
      setIsValidating(false);
    }
  }, [connectionId, schema, table, filePath, hasHeaders]);

  // Auto-validate when file or hasHeaders changes
  useEffect(() => {
    if (filePath) {
      handleValidate();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filePath, hasHeaders]);
  // Note: handleValidate intentionally excluded - we only want validation
  // to trigger when the user selects a file or changes hasHeaders, not
  // when schema/table props change (which would use stale filePath)

  const handleImport = useCallback(async () => {
    if (!filePath || !validation?.valid) return;

    setIsImporting(true);
    setResult(null);

    try {
      const importResult = await tauri.importCsv(connectionId, {
        schemaName: schema,
        tableName: table,
        filePath,
        hasHeaders,
      });

      if (importResult.success) {
        setResult({
          success: true,
          message: `Successfully imported ${importResult.rowsImported} rows!`,
        });

        // Trigger refresh and close after short delay
        setTimeout(() => {
          onSuccess();
          onClose();
        }, 1500);
      }
    } catch (err) {
      setResult({
        success: false,
        message: err instanceof Error ? err.message : typeof err === 'string' ? err : 'Import failed',
      });
    } finally {
      setIsImporting(false);
    }
  }, [connectionId, schema, table, filePath, hasHeaders, validation, onSuccess, onClose]);

  if (!isOpen) return null;

  const fileName = filePath?.split('/').pop() || filePath?.split('\\').pop();

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* Backdrop */}
      <div className="absolute inset-0 bg-black/50" onClick={onClose} />

      {/* Dialog */}
      <div className="relative w-full max-w-md mx-4 rounded-lg border border-theme-border-secondary bg-theme-bg-elevated shadow-2xl">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b border-theme-border-primary">
          <div className="flex items-center gap-2">
            <Upload className="w-5 h-5 text-blue-400" />
            <h2 className="text-lg font-semibold text-theme-text-primary">Import Data</h2>
          </div>
          <button
            onClick={onClose}
            className="p-1 rounded hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Content */}
        <div className="p-4 space-y-4">
          {/* Target table info */}
          <div className="text-sm text-theme-text-secondary">
            Import to: <span className="font-mono text-theme-text-primary">{schema}.{table}</span>
          </div>

          {/* File selection */}
          <div>
            <label className="block text-sm text-theme-text-secondary mb-1">CSV File</label>
            <div className="flex gap-2">
              <button
                onClick={handleSelectFile}
                className={cn(
                  'flex-1 px-3 py-2 rounded text-left',
                  'bg-theme-bg-surface border border-theme-border-primary',
                  'text-theme-text-secondary hover:bg-theme-bg-hover',
                  'flex items-center gap-2'
                )}
              >
                <FileText className="w-4 h-4" />
                {fileName || 'Select CSV file...'}
              </button>
            </div>
          </div>

          {/* Options */}
          <div>
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                checked={hasHeaders}
                onChange={(e) => setHasHeaders(e.target.checked)}
                className="w-4 h-4 rounded"
              />
              <span className="text-sm text-theme-text-secondary">CSV has headers</span>
            </label>
            <p className="text-xs text-theme-text-tertiary mt-1 ml-6">
              Skip the first row if it contains column names
            </p>
          </div>

          {/* Validation status */}
          {isValidating && (
            <div className="flex items-center gap-2 text-sm text-theme-text-secondary">
              <Loader2 className="w-4 h-4 animate-spin" />
              Validating CSV...
            </div>
          )}

          {validation && !isValidating && (
            <div
              className={cn(
                'p-3 rounded text-sm',
                validation.valid
                  ? 'bg-green-500/20 border border-green-500/30'
                  : 'bg-red-500/20 border border-red-500/30'
              )}
            >
              <div className="flex items-center gap-2 mb-1">
                {validation.valid ? (
                  <CheckCircle className="w-4 h-4 text-green-400" />
                ) : (
                  <XCircle className="w-4 h-4 text-red-400" />
                )}
                <span className={validation.valid ? 'text-green-300' : 'text-red-300'}>
                  {validation.valid ? 'Validation passed' : 'Validation failed'}
                </span>
              </div>
              {validation.valid ? (
                <p className="text-theme-text-secondary">
                  {validation.rowCount} rows will be imported ({validation.columnCount} columns)
                </p>
              ) : (
                <p className="text-red-300">{validation.error}</p>
              )}
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
        <div className="flex items-center justify-end gap-2 p-4 border-t border-theme-border-primary">
          <button
            onClick={onClose}
            disabled={isImporting}
            className="px-4 py-2 rounded bg-theme-bg-hover hover:bg-theme-bg-active text-theme-text-secondary disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            onClick={handleImport}
            disabled={isImporting || !validation?.valid}
            className="px-4 py-2 rounded bg-blue-600 hover:bg-blue-500 text-white disabled:opacity-50 flex items-center gap-2"
          >
            {isImporting && <Loader2 className="w-4 h-4 animate-spin" />}
            Import
          </button>
        </div>
      </div>
    </div>
  );
}
