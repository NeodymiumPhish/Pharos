import { useState, useCallback, useEffect } from 'react';
import { X, Copy, Loader2 } from 'lucide-react';
import { cn } from '@/lib/cn';
import * as tauri from '@/lib/tauri';

interface CloneTableDialogProps {
  isOpen: boolean;
  onClose: () => void;
  connectionId: string;
  schema: string;
  table: string;
  type: 'table' | 'view';
  onSuccess: () => void;
}

export function CloneTableDialog({
  isOpen,
  onClose,
  connectionId,
  schema,
  table,
  type,
  onSuccess,
}: CloneTableDialogProps) {
  const [newTableName, setNewTableName] = useState('');
  const [includeData, setIncludeData] = useState(false);
  const [isCloning, setIsCloning] = useState(false);
  const [result, setResult] = useState<{ success: boolean; message: string } | null>(null);

  // Reset form when dialog opens
  useEffect(() => {
    if (isOpen) {
      setNewTableName(`${table}_copy`);
      setIncludeData(false);
      setResult(null);
    }
  }, [isOpen, table]);

  const handleClone = useCallback(async () => {
    if (!newTableName.trim()) {
      setResult({ success: false, message: 'Please enter a table name' });
      return;
    }

    setIsCloning(true);
    setResult(null);

    try {
      const cloneResult = await tauri.cloneTable(connectionId, {
        sourceSchema: schema,
        sourceTable: table,
        targetSchema: schema,
        targetTable: newTableName.trim(),
        includeData,
      });

      if (cloneResult.success) {
        const message = includeData && cloneResult.rowsCopied !== null
          ? `Table cloned successfully! ${cloneResult.rowsCopied} rows copied.`
          : 'Table structure cloned successfully!';
        setResult({ success: true, message });

        // Trigger schema refresh and close after short delay
        setTimeout(() => {
          onSuccess();
          onClose();
        }, 1000);
      }
    } catch (err) {
      setResult({
        success: false,
        message: err instanceof Error ? err.message : 'Clone failed',
      });
    } finally {
      setIsCloning(false);
    }
  }, [connectionId, schema, table, newTableName, includeData, onSuccess, onClose]);

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* Backdrop */}
      <div className="absolute inset-0 bg-black/50" onClick={onClose} />

      {/* Dialog */}
      <div className="relative w-full max-w-md mx-4 rounded-lg border border-theme-border-secondary bg-theme-bg-elevated shadow-2xl">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b border-theme-border-primary">
          <div className="flex items-center gap-2">
            <Copy className="w-5 h-5 text-emerald-400" />
            <h2 className="text-lg font-semibold text-theme-text-primary">Clone Table</h2>
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
          {/* Source table info */}
          <div className="text-sm text-theme-text-secondary">
            Cloning: <span className="font-mono text-theme-text-primary">{schema}.{table}</span>
            {type === 'view' && <span className="ml-2 text-cyan-400">(view)</span>}
          </div>

          {/* New table name */}
          <div>
            <label className="block text-sm text-theme-text-secondary mb-1">New Table Name</label>
            <input
              type="text"
              value={newTableName}
              onChange={(e) => setNewTableName(e.target.value)}
              className={cn(
                'w-full px-3 py-2 rounded',
                'bg-theme-bg-surface border border-theme-border-primary',
                'text-theme-text-primary placeholder-theme-text-muted',
                'focus:outline-none focus:border-theme-border-secondary'
              )}
              placeholder="Enter new table name"
            />
          </div>

          {/* Clone options */}
          <div className="space-y-2">
            <label className="flex items-center gap-3 cursor-pointer">
              <input
                type="radio"
                name="cloneType"
                checked={!includeData}
                onChange={() => setIncludeData(false)}
                className="w-4 h-4 text-blue-600 focus:ring-blue-500"
              />
              <div>
                <span className="text-sm text-theme-text-primary">Clone Structure Only</span>
                <p className="text-xs text-theme-text-tertiary">Creates an empty table with the same columns and constraints</p>
              </div>
            </label>
            <label className="flex items-center gap-3 cursor-pointer">
              <input
                type="radio"
                name="cloneType"
                checked={includeData}
                onChange={() => setIncludeData(true)}
                className="w-4 h-4 text-blue-600 focus:ring-blue-500"
              />
              <div>
                <span className="text-sm text-theme-text-primary">Clone Structure & Data</span>
                <p className="text-xs text-theme-text-tertiary">Creates a table with all rows copied from the source</p>
              </div>
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
        <div className="flex items-center justify-end gap-2 p-4 border-t border-theme-border-primary">
          <button
            onClick={onClose}
            disabled={isCloning}
            className="px-4 py-2 rounded bg-theme-bg-hover hover:bg-theme-bg-active text-theme-text-secondary disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            onClick={handleClone}
            disabled={isCloning || !newTableName.trim()}
            className="px-4 py-2 rounded bg-emerald-600 hover:bg-emerald-500 text-white disabled:opacity-50 flex items-center gap-2"
          >
            {isCloning && <Loader2 className="w-4 h-4 animate-spin" />}
            Clone
          </button>
        </div>
      </div>
    </div>
  );
}
