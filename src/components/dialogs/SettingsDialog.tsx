import { useState, useCallback, useEffect } from 'react';
import { X, Settings, Monitor, Sun, Moon, Loader2, Keyboard, RotateCcw, Edit2 } from 'lucide-react';
import { cn } from '@/lib/cn';
import { useSettingsStore } from '@/stores/settingsStore';
import * as tauri from '@/lib/tauri';
import type { ThemeMode, EditorSettings, QuerySettings, UISettings, KeyboardShortcut, ShortcutModifier, NullDisplayFormat } from '@/lib/types';
import { DEFAULT_SHORTCUTS, ACCENT_COLORS } from '@/lib/types';
import { formatShortcut } from '@/hooks/useKeyboardShortcuts';

interface SettingsDialogProps {
  isOpen: boolean;
  onClose: () => void;
}

type SettingsTab = 'appearance' | 'editor' | 'query' | 'keyboard';

export function SettingsDialog({ isOpen, onClose }: SettingsDialogProps) {
  const settings = useSettingsStore((state) => state.settings);
  const updateTheme = useSettingsStore((state) => state.updateTheme);
  const updateEditorSettings = useSettingsStore((state) => state.updateEditorSettings);
  const updateQuerySettings = useSettingsStore((state) => state.updateQuerySettings);
  const updateUISettings = useSettingsStore((state) => state.updateUISettings);

  const [activeTab, setActiveTab] = useState<SettingsTab>('appearance');
  const [isSaving, setIsSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [localSettings, setLocalSettings] = useState(settings);

  // Sync local settings when dialog opens
  useEffect(() => {
    if (isOpen) {
      setLocalSettings(settings);
      setSaveError(null);
    }
  }, [isOpen, settings]);

  const handleThemeChange = (theme: ThemeMode) => {
    setLocalSettings((prev) => ({ ...prev, theme }));
  };

  const handleEditorChange = <K extends keyof EditorSettings>(key: K, value: EditorSettings[K]) => {
    setLocalSettings((prev) => ({
      ...prev,
      editor: { ...prev.editor, [key]: value },
    }));
  };

  const handleQueryChange = <K extends keyof QuerySettings>(key: K, value: QuerySettings[K]) => {
    setLocalSettings((prev) => ({
      ...prev,
      query: { ...prev.query, [key]: value },
    }));
  };

  const handleUIChange = <K extends keyof UISettings>(key: K, value: UISettings[K]) => {
    setLocalSettings((prev) => ({
      ...prev,
      ui: { ...prev.ui, [key]: value },
    }));
  };

  const handleSave = useCallback(async () => {
    setIsSaving(true);
    setSaveError(null);
    try {
      await tauri.saveSettings(localSettings);
      updateTheme(localSettings.theme);
      updateEditorSettings(localSettings.editor);
      updateQuerySettings(localSettings.query);
      updateUISettings(localSettings.ui);
      onClose();
    } catch (err) {
      console.error('Failed to save settings:', err);
      setSaveError(String(err));
    } finally {
      setIsSaving(false);
    }
  }, [localSettings, updateTheme, updateEditorSettings, updateQuerySettings, updateUISettings, onClose]);

  if (!isOpen) return null;

  const tabs: { id: SettingsTab; label: string }[] = [
    { id: 'appearance', label: 'Appearance' },
    { id: 'editor', label: 'Editor' },
    { id: 'query', label: 'Query' },
    { id: 'keyboard', label: 'Keyboard' },
  ];

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* Backdrop */}
      <div className="absolute inset-0 bg-black/50" onClick={onClose} />

      {/* Dialog */}
      <div className="relative w-full max-w-lg mx-4 rounded-lg border border-theme-border-secondary bg-theme-bg-elevated shadow-2xl">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b border-theme-border-primary">
          <div className="flex items-center gap-2">
            <Settings className="w-5 h-5 text-blue-400" />
            <h2 className="text-lg font-semibold text-theme-text-primary">Settings</h2>
          </div>
          <button
            onClick={onClose}
            className="p-1 rounded hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Tabs */}
        <div className="flex border-b border-theme-border-primary">
          {tabs.map((tab) => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className={cn(
                'flex-1 px-4 py-2 text-sm font-medium transition-colors',
                activeTab === tab.id
                  ? 'text-theme-text-primary border-b-2 border-blue-500'
                  : 'text-theme-text-tertiary hover:text-theme-text-secondary'
              )}
            >
              {tab.label}
            </button>
          ))}
        </div>

        {/* Content */}
        <div className="p-4 min-h-[300px]">
          {activeTab === 'appearance' && (
            <div className="space-y-4">
              <div>
                <label className="block text-sm text-theme-text-secondary mb-3">Theme</label>
                <div className="grid grid-cols-3 gap-2">
                  <ThemeButton
                    icon={<Monitor className="w-5 h-5" />}
                    label="Auto"
                    isActive={localSettings.theme === 'auto'}
                    onClick={() => handleThemeChange('auto')}
                  />
                  <ThemeButton
                    icon={<Sun className="w-5 h-5" />}
                    label="Light"
                    isActive={localSettings.theme === 'light'}
                    onClick={() => handleThemeChange('light')}
                  />
                  <ThemeButton
                    icon={<Moon className="w-5 h-5" />}
                    label="Dark"
                    isActive={localSettings.theme === 'dark'}
                    onClick={() => handleThemeChange('dark')}
                  />
                </div>
                <p className="mt-2 text-xs text-theme-text-muted">
                  {localSettings.theme === 'auto'
                    ? 'Automatically match your system appearance'
                    : localSettings.theme === 'light'
                      ? 'Always use light theme'
                      : 'Always use dark theme'}
                </p>
              </div>

              <div className="pt-4 border-t border-theme-border-primary">
                <label className="block text-sm text-theme-text-secondary mb-3">Accent Color</label>
                <div className="flex flex-wrap gap-3">
                  {ACCENT_COLORS.map((color) => (
                    <button
                      key={color.value}
                      onClick={() => handleUIChange('accentColor', color.value)}
                      className={cn(
                        "w-8 h-8 rounded-full transition-transform hover:scale-110 focus:outline-none ring-2 ring-offset-2 ring-offset-theme-bg-elevated",
                        localSettings.ui.accentColor === color.value
                          ? "ring-theme-text-primary scale-110"
                          : "ring-transparent"
                      )}
                      style={{ backgroundColor: color.value }}
                      title={color.name}
                    />
                  ))}
                </div>
              </div>

              <div className="pt-4 border-t border-theme-border-primary space-y-2">
                <ToggleSetting
                  label="Show Empty Schemas"
                  description="Display schemas with no tables in the navigator"
                  checked={localSettings.ui.showEmptySchemas}
                  onChange={(v) => handleUIChange('showEmptySchemas', v)}
                />
                <ToggleSetting
                  label="Zebra Striping"
                  description="Alternate row background colors in results grid"
                  checked={localSettings.ui.zebraStriping}
                  onChange={(v) => handleUIChange('zebraStriping', v)}
                />
                <ToggleSetting
                  label="Row Numbers"
                  description="Show row numbers in results grid"
                  checked={localSettings.ui.showRowNumbers ?? true}
                  onChange={(v) => handleUIChange('showRowNumbers', v)}
                />
              </div>

              <div className="pt-4 border-t border-theme-border-primary">
                <label className="block text-sm text-theme-text-secondary mb-1">NULL Display</label>
                <select
                  value={localSettings.ui.nullDisplay ?? 'NULL'}
                  onChange={(e) => handleUIChange('nullDisplay', e.target.value as NullDisplayFormat)}
                  className={cn(
                    'w-full px-3 py-2 rounded',
                    'bg-theme-bg-surface border border-theme-border-primary',
                    'text-theme-text-primary',
                    'focus:outline-none focus:border-theme-border-secondary'
                  )}
                >
                  <option value="NULL">NULL</option>
                  <option value="null">null</option>
                  <option value="(null)">(null)</option>
                  <option value="∅">∅ (empty set symbol)</option>
                  <option value="">(blank)</option>
                </select>
                <p className="mt-1 text-xs text-theme-text-muted">How NULL values are displayed in results</p>
              </div>

              <div className="pt-4 border-t border-theme-border-primary">
                <label className="block text-sm text-theme-text-secondary mb-1">Results Font Size</label>
                <div className="flex items-center gap-3">
                  <input
                    type="range"
                    min="9"
                    max="16"
                    value={localSettings.ui.resultsFontSize ?? 11}
                    onChange={(e) => handleUIChange('resultsFontSize', parseInt(e.target.value, 10))}
                    className="flex-1"
                  />
                  <span className="text-sm text-theme-text-primary w-8">{localSettings.ui.resultsFontSize ?? 11}px</span>
                </div>
                <p className="mt-1 text-xs text-theme-text-muted">Font size for the query results grid</p>
              </div>
            </div>
          )}

          {activeTab === 'editor' && (
            <div className="space-y-4">
              <div>
                <label className="block text-sm text-theme-text-secondary mb-1">Font Size</label>
                <div className="flex items-center gap-3">
                  <input
                    type="range"
                    min="10"
                    max="24"
                    value={localSettings.editor.fontSize}
                    onChange={(e) => handleEditorChange('fontSize', parseInt(e.target.value, 10))}
                    className="flex-1"
                  />
                  <span className="text-sm text-theme-text-primary w-8">{localSettings.editor.fontSize}px</span>
                </div>
              </div>

              <div>
                <label className="block text-sm text-theme-text-secondary mb-1">Font Family</label>
                <select
                  value={localSettings.editor.fontFamily}
                  onChange={(e) => handleEditorChange('fontFamily', e.target.value)}
                  className={cn(
                    'w-full px-3 py-2 rounded',
                    'bg-theme-bg-surface border border-theme-border-primary',
                    'text-theme-text-primary',
                    'focus:outline-none focus:border-theme-border-secondary'
                  )}
                >
                  <option value="JetBrains Mono, Monaco, Menlo, monospace">JetBrains Mono</option>
                  <option value="Monaco, Menlo, monospace">Monaco</option>
                  <option value="Menlo, Monaco, monospace">Menlo</option>
                  <option value="SF Mono, Monaco, Menlo, monospace">SF Mono</option>
                  <option value="Fira Code, Monaco, Menlo, monospace">Fira Code</option>
                </select>
              </div>

              <div>
                <label className="block text-sm text-theme-text-secondary mb-1">Tab Size</label>
                <select
                  value={localSettings.editor.tabSize}
                  onChange={(e) => handleEditorChange('tabSize', parseInt(e.target.value, 10))}
                  className={cn(
                    'w-full px-3 py-2 rounded',
                    'bg-theme-bg-surface border border-theme-border-primary',
                    'text-theme-text-primary',
                    'focus:outline-none focus:border-theme-border-secondary'
                  )}
                >
                  <option value="2">2 spaces</option>
                  <option value="4">4 spaces</option>
                </select>
              </div>

              <div className="space-y-2">
                <ToggleSetting
                  label="Word Wrap"
                  description="Wrap long lines in the editor"
                  checked={localSettings.editor.wordWrap}
                  onChange={(v) => handleEditorChange('wordWrap', v)}
                />
                <ToggleSetting
                  label="Minimap"
                  description="Show code minimap on the right side"
                  checked={localSettings.editor.minimap}
                  onChange={(v) => handleEditorChange('minimap', v)}
                />
                <ToggleSetting
                  label="Line Numbers"
                  description="Show line numbers in the gutter"
                  checked={localSettings.editor.lineNumbers}
                  onChange={(v) => handleEditorChange('lineNumbers', v)}
                />
              </div>
            </div>
          )}

          {activeTab === 'query' && (
            <div className="space-y-4">
              <div>
                <label className="block text-sm text-theme-text-secondary mb-1">Default Result Limit</label>
                <select
                  value={localSettings.query.defaultLimit}
                  onChange={(e) => handleQueryChange('defaultLimit', parseInt(e.target.value, 10))}
                  className={cn(
                    'w-full px-3 py-2 rounded',
                    'bg-theme-bg-surface border border-theme-border-primary',
                    'text-theme-text-primary',
                    'focus:outline-none focus:border-theme-border-secondary'
                  )}
                >
                  <option value="100">100 rows</option>
                  <option value="500">500 rows</option>
                  <option value="1000">1,000 rows</option>
                  <option value="5000">5,000 rows</option>
                  <option value="10000">10,000 rows</option>
                </select>
              </div>

              <div>
                <label className="block text-sm text-theme-text-secondary mb-1">Query Timeout</label>
                <select
                  value={localSettings.query.timeoutSeconds}
                  onChange={(e) => handleQueryChange('timeoutSeconds', parseInt(e.target.value, 10))}
                  className={cn(
                    'w-full px-3 py-2 rounded',
                    'bg-theme-bg-surface border border-theme-border-primary',
                    'text-theme-text-primary',
                    'focus:outline-none focus:border-theme-border-secondary'
                  )}
                >
                  <option value="10">10 seconds</option>
                  <option value="30">30 seconds</option>
                  <option value="60">1 minute</option>
                  <option value="300">5 minutes</option>
                  <option value="0">No timeout</option>
                </select>
              </div>

              <div className="space-y-2">
                <ToggleSetting
                  label="Auto-commit"
                  description="Automatically commit statements (disable for transaction mode)"
                  checked={localSettings.query.autoCommit}
                  onChange={(v) => handleQueryChange('autoCommit', v)}
                />
                <ToggleSetting
                  label="Confirm Destructive Queries"
                  description="Show confirmation for DELETE, DROP, TRUNCATE statements"
                  checked={localSettings.query.confirmDestructive}
                  onChange={(v) => handleQueryChange('confirmDestructive', v)}
                />
              </div>
            </div>
          )}

          {activeTab === 'keyboard' && (
            <KeyboardSettingsPanel
              shortcuts={localSettings.keyboard?.shortcuts ?? DEFAULT_SHORTCUTS}
              onShortcutChange={(id, shortcut) => {
                setLocalSettings((prev) => ({
                  ...prev,
                  keyboard: {
                    shortcuts: {
                      ...(prev.keyboard?.shortcuts ?? DEFAULT_SHORTCUTS),
                      [id]: shortcut,
                    },
                  },
                }));
              }}
              onReset={() => {
                setLocalSettings((prev) => ({
                  ...prev,
                  keyboard: { shortcuts: DEFAULT_SHORTCUTS },
                }));
              }}
            />
          )}
        </div>

        {/* Footer */}
        <div className="flex flex-col gap-2 p-4 border-t border-theme-border-primary">
          {saveError && (
            <div className="text-xs text-red-500 bg-red-500/10 px-3 py-2 rounded">
              {saveError}
            </div>
          )}
          <div className="flex items-center justify-end gap-2">
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

function ThemeButton({
  icon,
  label,
  isActive,
  onClick,
}: {
  icon: React.ReactNode;
  label: string;
  isActive: boolean;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className={cn(
        'flex flex-col items-center gap-2 p-4 rounded-lg border transition-all',
        isActive
          ? 'bg-blue-600/20 border-blue-500 text-theme-text-primary'
          : 'bg-theme-bg-surface border-theme-border-primary text-theme-text-tertiary hover:bg-theme-bg-hover hover:text-theme-text-secondary'
      )}
    >
      {icon}
      <span className="text-sm">{label}</span>
    </button>
  );
}

function ToggleSetting({
  label,
  description,
  checked,
  onChange,
}: {
  label: string;
  description: string;
  checked: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <div className="flex items-center justify-between py-2">
      <div>
        <div className="text-sm text-theme-text-primary">{label}</div>
        <div className="text-xs text-theme-text-muted">{description}</div>
      </div>
      <button
        onClick={() => onChange(!checked)}
        className={cn(
          'relative w-10 h-6 rounded-full transition-colors',
          checked ? 'bg-blue-600' : 'bg-theme-bg-active'
        )}
      >
        <div
          className={cn(
            'absolute top-1 w-4 h-4 rounded-full bg-white transition-transform',
            checked ? 'translate-x-5' : 'translate-x-1'
          )}
        />
      </button>
    </div>
  );
}

// Group shortcuts by category for better organization
const SHORTCUT_GROUPS: { label: string; ids: string[] }[] = [
  {
    label: 'Query',
    ids: ['query.run', 'query.save', 'query.cancel'],
  },
  {
    label: 'Tabs',
    ids: ['tab.new', 'tab.close', 'tab.reopen', 'tab.next', 'tab.prev'],
  },
  {
    label: 'Tab Switching',
    ids: ['tab.1', 'tab.2', 'tab.3', 'tab.4', 'tab.5', 'tab.6', 'tab.7', 'tab.8', 'tab.9'],
  },
  {
    label: 'Results',
    ids: ['results.copy', 'results.export'],
  },
];

function KeyboardSettingsPanel({
  shortcuts,
  onShortcutChange,
  onReset,
}: {
  shortcuts: Record<string, KeyboardShortcut>;
  onShortcutChange: (id: string, shortcut: KeyboardShortcut) => void;
  onReset: () => void;
}) {
  const [editingId, setEditingId] = useState<string | null>(null);

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Keyboard className="w-4 h-4 text-theme-text-tertiary" />
          <span className="text-sm text-theme-text-secondary">Keyboard Shortcuts</span>
        </div>
        <button
          onClick={onReset}
          className="flex items-center gap-1 px-2 py-1 text-xs text-theme-text-tertiary hover:text-theme-text-primary rounded hover:bg-theme-bg-hover"
        >
          <RotateCcw className="w-3 h-3" />
          Reset All
        </button>
      </div>

      <div className="space-y-4 max-h-[250px] overflow-y-auto pr-2">
        {SHORTCUT_GROUPS.map((group) => (
          <div key={group.label}>
            <div className="text-xs font-medium text-theme-text-muted uppercase tracking-wider mb-2">
              {group.label}
            </div>
            <div className="space-y-1">
              {group.ids.map((id) => {
                const shortcut = shortcuts[id];
                if (!shortcut) return null;
                return (
                  <ShortcutRow
                    key={id}
                    shortcut={shortcut}
                    isEditing={editingId === id}
                    onEdit={() => setEditingId(id)}
                    onSave={(newShortcut) => {
                      onShortcutChange(id, newShortcut);
                      setEditingId(null);
                    }}
                    onCancel={() => setEditingId(null)}
                  />
                );
              })}
            </div>
          </div>
        ))}
      </div>

      <p className="text-xs text-theme-text-muted">
        Click on a shortcut to edit it. Press Escape to cancel.
      </p>
    </div>
  );
}

function ShortcutRow({
  shortcut,
  isEditing,
  onEdit,
  onSave,
  onCancel,
}: {
  shortcut: KeyboardShortcut;
  isEditing: boolean;
  onEdit: () => void;
  onSave: (shortcut: KeyboardShortcut) => void;
  onCancel: () => void;
}) {
  const [captured, setCaptured] = useState<{ key: string; modifiers: ShortcutModifier[] } | null>(null);

  useEffect(() => {
    if (!isEditing) {
      setCaptured(null);
      return;
    }

    const handleKeyDown = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();

      // Escape cancels editing
      if (e.key === 'Escape' && !e.metaKey && !e.ctrlKey && !e.shiftKey && !e.altKey) {
        onCancel();
        return;
      }

      // Build modifiers array
      const modifiers: ShortcutModifier[] = [];
      if (e.metaKey || e.ctrlKey) modifiers.push('cmd');
      if (e.shiftKey) modifiers.push('shift');
      if (e.altKey) modifiers.push('alt');

      // Get the key (ignoring modifier-only presses)
      const key = e.key;
      if (['Meta', 'Control', 'Shift', 'Alt'].includes(key)) {
        return;
      }

      setCaptured({ key, modifiers });
    };

    window.addEventListener('keydown', handleKeyDown, true);
    return () => window.removeEventListener('keydown', handleKeyDown, true);
  }, [isEditing, onCancel]);

  // Auto-save when a key is captured
  useEffect(() => {
    if (captured && isEditing) {
      const timer = setTimeout(() => {
        onSave({
          ...shortcut,
          key: captured.key,
          modifiers: captured.modifiers,
        });
      }, 300);
      return () => clearTimeout(timer);
    }
  }, [captured, isEditing, onSave, shortcut]);

  if (isEditing) {
    return (
      <div className="flex items-center justify-between py-1.5 px-2 rounded bg-blue-600/20 border border-blue-500">
        <div className="flex-1 min-w-0">
          <div className="text-sm text-theme-text-primary truncate">{shortcut.label}</div>
          <div className="text-xs text-theme-text-muted truncate">{shortcut.description}</div>
        </div>
        <div className="ml-4 px-3 py-1.5 rounded bg-theme-bg-surface border-2 border-blue-500 text-xs text-theme-text-primary font-mono animate-pulse">
          {captured ? formatShortcut(captured) : 'Press keys...'}
        </div>
      </div>
    );
  }

  return (
    <div
      className="flex items-center justify-between py-1.5 px-2 rounded hover:bg-theme-bg-hover cursor-pointer group"
      onClick={onEdit}
    >
      <div className="flex-1 min-w-0">
        <div className="text-sm text-theme-text-primary truncate">{shortcut.label}</div>
        <div className="text-xs text-theme-text-muted truncate">{shortcut.description}</div>
      </div>
      <div className="ml-4 flex items-center gap-2">
        <div className="px-2 py-1 rounded bg-theme-bg-surface border border-theme-border-primary text-xs text-theme-text-secondary font-mono">
          {formatShortcut(shortcut)}
        </div>
        <Edit2 className="w-3 h-3 text-theme-text-tertiary opacity-0 group-hover:opacity-100 transition-opacity" />
      </div>
    </div>
  );
}
