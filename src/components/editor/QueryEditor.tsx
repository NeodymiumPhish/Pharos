import { useRef, useCallback, useEffect } from 'react';
import Editor, { OnMount, OnChange } from '@monaco-editor/react';
import type { editor, IDisposable, KeyCode } from 'monaco-editor';
import { useEditorStore } from '@/stores/editorStore';
import { useConnectionStore } from '@/stores/connectionStore';
import { useSettingsStore } from '@/stores/settingsStore';
import { createCompletionProvider, type SchemaMetadata } from './SqlAutocomplete';
import { DEFAULT_SHORTCUTS } from '@/lib/types';
import * as tauri from '@/lib/tauri';

/**
 * Map our shortcut key strings to Monaco KeyCode values
 */
function getMonacoKeyCode(key: string, monaco: typeof import('monaco-editor')): KeyCode | null {
  const keyLower = key.toLowerCase();

  // Special keys
  switch (keyLower) {
    case 'enter':
      return monaco.KeyCode.Enter;
    case 'escape':
      return monaco.KeyCode.Escape;
    case 'tab':
      return monaco.KeyCode.Tab;
    case 'backspace':
      return monaco.KeyCode.Backspace;
    case 'delete':
      return monaco.KeyCode.Delete;
    case 'arrowup':
      return monaco.KeyCode.UpArrow;
    case 'arrowdown':
      return monaco.KeyCode.DownArrow;
    case 'arrowleft':
      return monaco.KeyCode.LeftArrow;
    case 'arrowright':
      return monaco.KeyCode.RightArrow;
    case ' ':
      return monaco.KeyCode.Space;
  }

  // Bracket keys
  if (key === '[') return monaco.KeyCode.BracketLeft;
  if (key === ']') return monaco.KeyCode.BracketRight;

  // Number keys
  if (/^[0-9]$/.test(key)) {
    const num = parseInt(key, 10);
    // Monaco KeyCode.Digit0 through Digit9
    return (monaco.KeyCode.Digit0 + num) as KeyCode;
  }

  // Letter keys (A-Z)
  if (/^[a-z]$/i.test(key)) {
    const charCode = key.toUpperCase().charCodeAt(0) - 'A'.charCodeAt(0);
    return (monaco.KeyCode.KeyA + charCode) as KeyCode;
  }

  return null;
}

/**
 * Emit a custom event that the useKeyboardShortcuts hook will handle
 */
function emitShortcutEvent(shortcutId: string) {
  window.dispatchEvent(
    new CustomEvent('app-shortcut', { detail: { id: shortcutId } })
  );
}

interface QueryEditorProps {
  tabId: string;
  schemaMetadata?: SchemaMetadata | null;
}

// Custom dark theme for Liquid Glass aesthetic
const PHAROS_DARK_THEME: editor.IStandaloneThemeData = {
  base: 'vs-dark',
  inherit: true,
  rules: [
    { token: 'keyword', foreground: 'C586C0' },
    { token: 'keyword.sql', foreground: 'C586C0' },
    { token: 'string', foreground: 'CE9178' },
    { token: 'string.sql', foreground: 'CE9178' },
    { token: 'number', foreground: 'B5CEA8' },
    { token: 'comment', foreground: '6A9955', fontStyle: 'italic' },
    { token: 'operator', foreground: 'D4D4D4' },
    { token: 'identifier', foreground: '9CDCFE' },
    { token: 'type', foreground: '4EC9B0' },
    { token: 'predefined', foreground: '4FC1FF' },
  ],
  colors: {
    'editor.background': '#00000000', // Transparent
    'editor.foreground': '#D4D4D4',
    'editor.lineHighlightBackground': '#ffffff10',
    'editor.selectionBackground': '#264F78',
    'editor.inactiveSelectionBackground': '#3A3D41',
    'editorCursor.foreground': '#AEAFAD',
    'editorWhitespace.foreground': '#3B3B3B',
    'editorLineNumber.foreground': '#858585',
    'editorLineNumber.activeForeground': '#C6C6C6',
    'editor.selectionHighlightBackground': '#ADD6FF26',
    'editorIndentGuide.background1': '#404040',
    'editorIndentGuide.activeBackground1': '#707070',
    'editorWidget.background': '#1e1e1e',
    'editorSuggestWidget.background': '#1e1e1e',
    'editorSuggestWidget.border': '#454545',
    'editorSuggestWidget.selectedBackground': '#04395e',
  },
};

// Custom light theme for Liquid Glass aesthetic
const PHAROS_LIGHT_THEME: editor.IStandaloneThemeData = {
  base: 'vs',
  inherit: true,
  rules: [
    { token: 'keyword', foreground: 'AF00DB' },
    { token: 'keyword.sql', foreground: 'AF00DB' },
    { token: 'string', foreground: 'A31515' },
    { token: 'string.sql', foreground: 'A31515' },
    { token: 'number', foreground: '098658' },
    { token: 'comment', foreground: '008000', fontStyle: 'italic' },
    { token: 'operator', foreground: '000000' },
    { token: 'identifier', foreground: '001080' },
    { token: 'type', foreground: '267F99' },
    { token: 'predefined', foreground: '0000FF' },
  ],
  colors: {
    'editor.background': '#00000000', // Transparent
    'editor.foreground': '#000000',
    'editor.lineHighlightBackground': '#00000008',
    'editor.selectionBackground': '#ADD6FF',
    'editor.inactiveSelectionBackground': '#E5EBF1',
    'editorCursor.foreground': '#000000',
    'editorWhitespace.foreground': '#CCCCCC',
    'editorLineNumber.foreground': '#6E7681',
    'editorLineNumber.activeForeground': '#1B1F23',
    'editor.selectionHighlightBackground': '#ADD6FF80',
    'editorIndentGuide.background1': '#D3D3D3',
    'editorIndentGuide.activeBackground1': '#939393',
    'editorWidget.background': '#F3F3F3',
    'editorSuggestWidget.background': '#F3F3F3',
    'editorSuggestWidget.border': '#C8C8C8',
    'editorSuggestWidget.selectedBackground': '#D6EBFF',
  },
};

// Debounce delay for validation (ms)
const VALIDATION_DEBOUNCE_MS = 500;

export function QueryEditor({ tabId, schemaMetadata }: QueryEditorProps) {
  const editorRef = useRef<editor.IStandaloneCodeEditor | null>(null);
  const monacoRef = useRef<typeof import('monaco-editor') | null>(null);
  const completionProviderRef = useRef<IDisposable | null>(null);
  const schemaMetadataRef = useRef<SchemaMetadata | null>(null);
  const validationTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const tab = useEditorStore((state) => state.getTab(tabId));
  const updateTabSql = useEditorStore((state) => state.updateTabSql);
  const updateCursorPosition = useEditorStore((state) => state.updateCursorPosition);
  const setTabValidation = useEditorStore((state) => state.setTabValidation);
  const setTabValidating = useEditorStore((state) => state.setTabValidating);
  const activeConnection = useConnectionStore((state) => state.getActiveConnection());
  const activeConnectionId = useConnectionStore((state) => state.activeConnectionId);
  const selectedSchema = useConnectionStore((state) => state.getActiveSelectedSchema());
  const editorSettings = useSettingsStore((state) => state.settings.editor);
  const theme = useSettingsStore((state) => state.settings.theme);
  const getEffectiveTheme = useSettingsStore((state) => state.getEffectiveTheme);

  // Update the metadata ref when it changes
  useEffect(() => {
    schemaMetadataRef.current = schemaMetadata ?? null;
  }, [schemaMetadata]);

  // Validate SQL and update editor markers
  const validateSql = useCallback(
    async (sql: string) => {
      if (!activeConnectionId || !activeConnection || activeConnection.status !== 'connected') {
        // Clear markers when not connected
        if (editorRef.current && monacoRef.current) {
          const model = editorRef.current.getModel();
          if (model) {
            monacoRef.current.editor.setModelMarkers(model, 'sql-validation', []);
          }
        }
        setTabValidation(tabId, { isValid: true, isValidating: false, error: null });
        return;
      }

      const trimmedSql = sql.trim();
      if (!trimmedSql) {
        // Clear markers for empty queries
        if (editorRef.current && monacoRef.current) {
          const model = editorRef.current.getModel();
          if (model) {
            monacoRef.current.editor.setModelMarkers(model, 'sql-validation', []);
          }
        }
        setTabValidation(tabId, { isValid: true, isValidating: false, error: null });
        return;
      }

      setTabValidating(tabId, true);

      try {
        const result = await tauri.validateSql(activeConnectionId, sql, selectedSchema);

        if (editorRef.current && monacoRef.current) {
          const model = editorRef.current.getModel();
          if (model) {
            if (result.valid) {
              // Clear any existing markers
              monacoRef.current.editor.setModelMarkers(model, 'sql-validation', []);
              setTabValidation(tabId, { isValid: true, isValidating: false, error: null });
            } else if (result.error) {
              // Add error marker only if we have a meaningful position
              // PostgreSQL often returns position 1 for semantic errors (like missing GROUP BY)
              // which would incorrectly highlight the first token
              const line = result.error.line ?? 1;
              const column = result.error.column ?? 1;
              const hasMeaningfulPosition = line > 1 || column > 1;

              if (hasMeaningfulPosition) {
                const endColumn = column + 10; // Highlight ~10 chars from error position
                const markers: editor.IMarkerData[] = [
                  {
                    severity: monacoRef.current.MarkerSeverity.Error,
                    message: result.error.message,
                    startLineNumber: line,
                    startColumn: column,
                    endLineNumber: line,
                    endColumn: Math.min(endColumn, model.getLineMaxColumn(line)),
                  },
                ];
                monacoRef.current.editor.setModelMarkers(model, 'sql-validation', markers);
              } else {
                // Clear markers for errors without meaningful position
                // The error will still be shown in the toolbar
                monacoRef.current.editor.setModelMarkers(model, 'sql-validation', []);
              }

              setTabValidation(tabId, {
                isValid: false,
                isValidating: false,
                error: result.error,
              });
            }
          }
        }
      } catch (err) {
        // Validation request failed (e.g., network error) - don't show as SQL error
        console.error('SQL validation failed:', err);
        setTabValidation(tabId, { isValid: true, isValidating: false, error: null });
      }
    },
    [activeConnectionId, activeConnection, selectedSchema, tabId, setTabValidation, setTabValidating]
  );

  // Debounced validation trigger
  const triggerValidation = useCallback(
    (sql: string) => {
      if (validationTimeoutRef.current) {
        clearTimeout(validationTimeoutRef.current);
      }
      validationTimeoutRef.current = setTimeout(() => {
        validateSql(sql);
      }, VALIDATION_DEBOUNCE_MS);
    },
    [validateSql]
  );

  const handleEditorMount: OnMount = useCallback(
    (editor, monaco) => {
      editorRef.current = editor;
      monacoRef.current = monaco;

      // Define custom themes
      monaco.editor.defineTheme('pharos-dark', PHAROS_DARK_THEME);
      monaco.editor.defineTheme('pharos-light', PHAROS_LIGHT_THEME);

      // Set initial theme based on settings
      const effectiveTheme = getEffectiveTheme();
      monaco.editor.setTheme(effectiveTheme === 'dark' ? 'pharos-dark' : 'pharos-light');

      // Register custom completion provider
      completionProviderRef.current = monaco.languages.registerCompletionItemProvider(
        'sql',
        createCompletionProvider(() => schemaMetadataRef.current)
      );

      // Track cursor position
      editor.onDidChangeCursorPosition((e) => {
        updateCursorPosition(tabId, e.position.lineNumber, e.position.column);
      });

      // Register all app keyboard shortcuts in Monaco
      // This ensures shortcuts work when the editor has focus
      const shortcuts = DEFAULT_SHORTCUTS;

      for (const [shortcutId, shortcut] of Object.entries(shortcuts)) {
        const keyCode = getMonacoKeyCode(shortcut.key, monaco);
        if (keyCode === null) continue;

        // Build Monaco keybinding with modifiers
        let keybinding = keyCode as number;
        if (shortcut.modifiers.includes('cmd')) {
          keybinding = monaco.KeyMod.CtrlCmd | keybinding;
        }
        if (shortcut.modifiers.includes('shift')) {
          keybinding = monaco.KeyMod.Shift | keybinding;
        }
        if (shortcut.modifiers.includes('alt')) {
          keybinding = monaco.KeyMod.Alt | keybinding;
        }

        // Register the shortcut to emit a custom event
        editor.addCommand(keybinding, () => {
          emitShortcutEvent(shortcutId);
        });
      }

      // Focus the editor
      editor.focus();
    },
    [tabId, updateCursorPosition, getEffectiveTheme]
  );

  // Update Monaco theme when settings change
  useEffect(() => {
    if (editorRef.current) {
      const effectiveTheme = getEffectiveTheme();
      const monacoApi = (window as any).monaco;
      if (monacoApi) {
        monacoApi.editor.setTheme(effectiveTheme === 'dark' ? 'pharos-dark' : 'pharos-light');
      }
    }
  }, [theme, getEffectiveTheme]);

  // Cleanup completion provider and validation timeout on unmount
  useEffect(() => {
    return () => {
      if (completionProviderRef.current) {
        completionProviderRef.current.dispose();
      }
      if (validationTimeoutRef.current) {
        clearTimeout(validationTimeoutRef.current);
      }
    };
  }, []);

  // Re-validate when connection or schema changes
  useEffect(() => {
    if (tab?.sql) {
      triggerValidation(tab.sql);
    }
  }, [activeConnectionId, selectedSchema, activeConnection?.status]);

  const handleChange: OnChange = useCallback(
    (value) => {
      if (value !== undefined) {
        updateTabSql(tabId, value);
        triggerValidation(value);
      }
    },
    [tabId, updateTabSql, triggerValidation]
  );

  // Focus editor when tab becomes active
  useEffect(() => {
    if (editorRef.current) {
      editorRef.current.focus();
    }
  }, [tabId]);

  if (!tab) {
    return null;
  }

  return (
    <div className="h-full w-full">
      <Editor
        height="100%"
        language="sql"
        value={tab.sql}
        onChange={handleChange}
        onMount={handleEditorMount}
        options={{
          fontSize: editorSettings.fontSize,
          fontFamily: editorSettings.fontFamily,
          fontLigatures: true,
          minimap: { enabled: editorSettings.minimap },
          scrollBeyondLastLine: false,
          lineNumbers: editorSettings.lineNumbers ? 'on' : 'off',
          glyphMargin: false,
          folding: true,
          lineDecorationsWidth: 10,
          lineNumbersMinChars: 3,
          renderLineHighlight: 'line',
          scrollbar: {
            vertical: 'auto',
            horizontal: 'auto',
            verticalScrollbarSize: 10,
            horizontalScrollbarSize: 10,
          },
          padding: { top: 10, bottom: 10 },
          contextmenu: true,
          quickSuggestions: true,
          suggestOnTriggerCharacters: true,
          wordWrap: editorSettings.wordWrap ? 'on' : 'off',
          automaticLayout: true,
          tabSize: editorSettings.tabSize,
          insertSpaces: true,
          readOnly: !activeConnection || activeConnection.status !== 'connected',
        }}
        loading={
          <div className="flex items-center justify-center h-full text-theme-text-muted">
            Loading editor...
          </div>
        }
      />
    </div>
  );
}
