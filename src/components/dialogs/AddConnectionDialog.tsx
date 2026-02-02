import { useState, useCallback } from 'react';
import { X, Database, TestTube, Loader2 } from 'lucide-react';
import { cn } from '@/lib/cn';
import { useConnectionStore } from '@/stores/connectionStore';
import * as tauri from '@/lib/tauri';
import type { ConnectionConfig } from '@/lib/types';

interface AddConnectionDialogProps {
  isOpen: boolean;
  onClose: () => void;
}

export function AddConnectionDialog({ isOpen, onClose }: AddConnectionDialogProps) {
  const addConnection = useConnectionStore((state) => state.addConnection);

  const [formData, setFormData] = useState({
    name: '',
    host: 'localhost',
    port: '5432',
    database: 'postgres',
    username: 'postgres',
    password: '',
  });

  const [isTesting, setIsTesting] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [testResult, setTestResult] = useState<{ success: boolean; message: string } | null>(null);

  const handleChange = (field: keyof typeof formData) => (e: React.ChangeEvent<HTMLInputElement>) => {
    setFormData((prev) => ({ ...prev, [field]: e.target.value }));
    setTestResult(null);
  };

  const buildConfig = useCallback((): ConnectionConfig => {
    return {
      id: crypto.randomUUID(),
      name: formData.name || `${formData.host}:${formData.port}`,
      host: formData.host,
      port: parseInt(formData.port, 10),
      database: formData.database,
      username: formData.username,
      password: formData.password,
    };
  }, [formData]);

  const handleTest = useCallback(async () => {
    setIsTesting(true);
    setTestResult(null);

    try {
      const config = buildConfig();
      const result = await tauri.testConnection(config);

      if (result.success) {
        setTestResult({
          success: true,
          message: `Connection successful! (${result.latency_ms}ms)`,
        });
      } else {
        setTestResult({
          success: false,
          message: result.error || 'Connection failed',
        });
      }
    } catch (err) {
      setTestResult({
        success: false,
        message: err instanceof Error ? err.message : 'Unknown error',
      });
    } finally {
      setIsTesting(false);
    }
  }, [buildConfig]);

  const handleSave = useCallback(async () => {
    setIsSaving(true);

    try {
      const config = buildConfig();

      // Save to Tauri backend
      await tauri.saveConnection(config);

      // Update local state
      addConnection(config);

      onClose();

      // Reset form
      setFormData({
        name: '',
        host: 'localhost',
        port: '5432',
        database: 'postgres',
        username: 'postgres',
        password: '',
      });
      setTestResult(null);
    } catch (err) {
      setTestResult({
        success: false,
        message: `Failed to save: ${err instanceof Error ? err.message : 'Unknown error'}`,
      });
    } finally {
      setIsSaving(false);
    }
  }, [buildConfig, addConnection, onClose]);

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* Backdrop */}
      <div className="absolute inset-0 bg-black/50" onClick={onClose} />

      {/* Dialog */}
      <div
        className="relative w-full max-w-md mx-4 rounded-lg border border-theme-border-secondary bg-theme-bg-elevated shadow-2xl"
      >
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b border-theme-border-primary">
          <div className="flex items-center gap-2">
            <Database className="w-5 h-5 text-blue-400" />
            <h2 className="text-lg font-semibold text-theme-text-primary">New Connection</h2>
          </div>
          <button
            onClick={onClose}
            className="p-1 rounded hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Form */}
        <div className="p-4 space-y-4">
          <div>
            <label className="block text-sm text-theme-text-secondary mb-1">Connection Name</label>
            <input
              type="text"
              placeholder="My Database"
              value={formData.name}
              onChange={handleChange('name')}
              className={cn(
                'w-full px-3 py-2 rounded',
                'bg-theme-bg-surface border border-theme-border-primary',
                'text-theme-text-primary placeholder-theme-text-muted',
                'focus:outline-none focus:border-theme-border-secondary'
              )}
            />
          </div>

          <div className="grid grid-cols-3 gap-3">
            <div className="col-span-2">
              <label className="block text-sm text-theme-text-secondary mb-1">Host</label>
              <input
                type="text"
                value={formData.host}
                onChange={handleChange('host')}
                className={cn(
                  'w-full px-3 py-2 rounded',
                  'bg-theme-bg-surface border border-theme-border-primary',
                  'text-theme-text-primary placeholder-theme-text-muted',
                  'focus:outline-none focus:border-theme-border-secondary'
                )}
              />
            </div>
            <div>
              <label className="block text-sm text-theme-text-secondary mb-1">Port</label>
              <input
                type="text"
                value={formData.port}
                onChange={handleChange('port')}
                className={cn(
                  'w-full px-3 py-2 rounded',
                  'bg-theme-bg-surface border border-theme-border-primary',
                  'text-theme-text-primary placeholder-theme-text-muted',
                  'focus:outline-none focus:border-theme-border-secondary'
                )}
              />
            </div>
          </div>

          <div>
            <label className="block text-sm text-theme-text-secondary mb-1">Database</label>
            <input
              type="text"
              value={formData.database}
              onChange={handleChange('database')}
              className={cn(
                'w-full px-3 py-2 rounded',
                'bg-theme-bg-surface border border-theme-border-primary',
                'text-theme-text-primary placeholder-theme-text-muted',
                'focus:outline-none focus:border-theme-border-secondary'
              )}
            />
          </div>

          <div>
            <label className="block text-sm text-theme-text-secondary mb-1">Username</label>
            <input
              type="text"
              value={formData.username}
              onChange={handleChange('username')}
              className={cn(
                'w-full px-3 py-2 rounded',
                'bg-theme-bg-surface border border-theme-border-primary',
                'text-theme-text-primary placeholder-theme-text-muted',
                'focus:outline-none focus:border-theme-border-secondary'
              )}
            />
          </div>

          <div>
            <label className="block text-sm text-theme-text-secondary mb-1">Password</label>
            <input
              type="password"
              value={formData.password}
              onChange={handleChange('password')}
              className={cn(
                'w-full px-3 py-2 rounded',
                'bg-theme-bg-surface border border-theme-border-primary',
                'text-theme-text-primary placeholder-theme-text-muted',
                'focus:outline-none focus:border-theme-border-secondary'
              )}
            />
          </div>

          {/* Test result */}
          {testResult && (
            <div
              className={cn(
                'p-3 rounded text-sm',
                testResult.success
                  ? 'bg-green-500/20 text-green-700 dark:text-green-300 border border-green-500/30'
                  : 'bg-red-500/20 text-red-700 dark:text-red-300 border border-red-500/30'
              )}
            >
              {testResult.message}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between p-4 border-t border-theme-border-primary">
          <button
            onClick={handleTest}
            disabled={isTesting || isSaving}
            className={cn(
              'flex items-center gap-2 px-4 py-2 rounded',
              'bg-theme-bg-hover hover:bg-theme-bg-active text-theme-text-secondary',
              'disabled:opacity-50 disabled:cursor-not-allowed'
            )}
          >
            {isTesting ? (
              <Loader2 className="w-4 h-4 animate-spin" />
            ) : (
              <TestTube className="w-4 h-4" />
            )}
            Test Connection
          </button>

          <div className="flex items-center gap-2">
            <button
              onClick={onClose}
              disabled={isSaving}
              className="px-4 py-2 rounded bg-theme-bg-hover hover:bg-theme-bg-active text-theme-text-secondary disabled:opacity-50"
            >
              Cancel
            </button>
            <button
              onClick={handleSave}
              disabled={isSaving}
              className="px-4 py-2 rounded bg-blue-600 hover:bg-blue-500 text-white disabled:opacity-50 flex items-center gap-2"
            >
              {isSaving && <Loader2 className="w-4 h-4 animate-spin" />}
              Save
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
