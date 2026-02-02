import { useState, useCallback, useEffect } from 'react';
import { X, Save, FolderPlus } from 'lucide-react';
import { cn } from '@/lib/cn';
import { useSavedQueryStore } from '@/stores/savedQueryStore';
import { useConnectionStore } from '@/stores/connectionStore';

interface SaveQueryDialogProps {
  isOpen: boolean;
  onClose: () => void;
  sql: string;
  initialName?: string;
  queryId?: string; // If provided, update existing query
}

export function SaveQueryDialog({
  isOpen,
  onClose,
  sql,
  initialName = '',
  queryId,
}: SaveQueryDialogProps) {
  const [name, setName] = useState(initialName);
  const [folder, setFolder] = useState('');
  const [showNewFolder, setShowNewFolder] = useState(false);
  const [newFolderName, setNewFolderName] = useState('');
  const [isSaving, setIsSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const { createQuery, updateQuery, getFolders } = useSavedQueryStore();
  const activeConnectionId = useConnectionStore((state) => state.activeConnectionId);
  const folders = getFolders();

  useEffect(() => {
    if (isOpen) {
      setName(initialName);
      setFolder('');
      setShowNewFolder(false);
      setNewFolderName('');
      setError(null);
    }
  }, [isOpen, initialName]);

  const handleSave = useCallback(async () => {
    if (!name.trim()) {
      setError('Query name is required');
      return;
    }

    setIsSaving(true);
    setError(null);

    const finalFolder = showNewFolder ? newFolderName.trim() : folder;

    try {
      if (queryId) {
        await updateQuery({
          id: queryId,
          name: name.trim(),
          folder: finalFolder || undefined,
          sql,
        });
      } else {
        await createQuery({
          name: name.trim(),
          folder: finalFolder || undefined,
          sql,
          connectionId: activeConnectionId || undefined,
        });
      }
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save query');
    } finally {
      setIsSaving(false);
    }
  }, [name, folder, showNewFolder, newFolderName, sql, queryId, activeConnectionId, createQuery, updateQuery, onClose]);

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        handleSave();
      } else if (e.key === 'Escape') {
        onClose();
      }
    },
    [handleSave, onClose]
  );

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* Backdrop */}
      <div className="absolute inset-0 bg-black/60" onClick={onClose} />

      {/* Dialog */}
      <div
        className={cn(
          'relative w-[400px] bg-theme-bg-elevated rounded-xl shadow-2xl border border-theme-border-secondary',
          'animate-in fade-in zoom-in-95 duration-200'
        )}
        onKeyDown={handleKeyDown}
      >
        {/* Header */}
        <div className="flex items-center justify-between px-5 py-4 border-b border-theme-border-primary">
          <h2 className="text-lg font-semibold text-theme-text-primary">
            {queryId ? 'Update Query' : 'Save Query'}
          </h2>
          <button
            onClick={onClose}
            className="p-1.5 rounded-lg hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary transition-colors"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Body */}
        <div className="px-5 py-4 space-y-4">
          {/* Name */}
          <div>
            <label className="block text-sm font-medium text-theme-text-secondary mb-1.5">
              Name
            </label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="My Query"
              autoFocus
              className={cn(
                'w-full px-3 py-2.5 rounded-lg',
                'bg-theme-bg-surface border border-theme-border-primary',
                'text-sm text-theme-text-primary placeholder-theme-text-muted',
                'focus:outline-none focus:border-theme-border-secondary',
                'transition-colors duration-200'
              )}
            />
          </div>

          {/* Folder */}
          <div>
            <label className="block text-sm font-medium text-theme-text-secondary mb-1.5">
              Folder (optional)
            </label>
            {!showNewFolder ? (
              <div className="flex gap-2">
                <select
                  value={folder}
                  onChange={(e) => setFolder(e.target.value)}
                  className={cn(
                    'flex-1 px-3 py-2.5 rounded-lg',
                    'bg-theme-bg-surface border border-theme-border-primary',
                    'text-sm text-theme-text-primary',
                    'focus:outline-none focus:border-theme-border-secondary',
                    'transition-colors duration-200'
                  )}
                >
                  <option value="">No folder</option>
                  {folders.map((f) => (
                    <option key={f} value={f}>
                      {f}
                    </option>
                  ))}
                </select>
                <button
                  onClick={() => setShowNewFolder(true)}
                  className="p-2.5 rounded-lg bg-theme-bg-surface border border-theme-border-primary hover:bg-theme-bg-hover transition-colors"
                  title="Create new folder"
                >
                  <FolderPlus className="w-4 h-4 text-theme-text-tertiary" />
                </button>
              </div>
            ) : (
              <div className="flex gap-2">
                <input
                  type="text"
                  value={newFolderName}
                  onChange={(e) => setNewFolderName(e.target.value)}
                  placeholder="New folder name"
                  className={cn(
                    'flex-1 px-3 py-2.5 rounded-lg',
                    'bg-theme-bg-surface border border-theme-border-primary',
                    'text-sm text-theme-text-primary placeholder-theme-text-muted',
                    'focus:outline-none focus:border-theme-border-secondary',
                    'transition-colors duration-200'
                  )}
                />
                <button
                  onClick={() => {
                    setShowNewFolder(false);
                    setNewFolderName('');
                  }}
                  className="px-3 py-2 rounded-lg bg-theme-bg-hover hover:bg-theme-bg-active text-sm text-theme-text-secondary transition-colors"
                >
                  Cancel
                </button>
              </div>
            )}
          </div>

          {/* Error */}
          {error && (
            <div className="px-3 py-2 rounded-lg bg-red-500/10 border border-red-500/20 text-red-400 text-sm">
              {error}
            </div>
          )}

          {/* SQL Preview */}
          <div>
            <label className="block text-sm font-medium text-theme-text-secondary mb-1.5">
              Query Preview
            </label>
            <div
              className={cn(
                'w-full px-3 py-2.5 rounded-lg max-h-32 overflow-auto',
                'bg-theme-bg-surface border border-theme-border-primary',
                'text-xs text-theme-text-tertiary font-mono whitespace-pre-wrap'
              )}
            >
              {sql.length > 500 ? sql.substring(0, 500) + '...' : sql}
            </div>
          </div>
        </div>

        {/* Footer */}
        <div className="flex items-center justify-end gap-3 px-5 py-4 border-t border-theme-border-primary">
          <button
            onClick={onClose}
            className="px-4 py-2 rounded-lg hover:bg-theme-bg-hover text-sm text-theme-text-secondary transition-colors"
          >
            Cancel
          </button>
          <button
            onClick={handleSave}
            disabled={isSaving || !name.trim()}
            className={cn(
              'flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium transition-all duration-200',
              'bg-emerald-600 hover:bg-emerald-500 text-white',
              'disabled:opacity-40 disabled:cursor-not-allowed disabled:hover:bg-emerald-600'
            )}
          >
            <Save className="w-4 h-4" />
            {isSaving ? 'Saving...' : queryId ? 'Update' : 'Save'}
          </button>
        </div>
      </div>
    </div>
  );
}
