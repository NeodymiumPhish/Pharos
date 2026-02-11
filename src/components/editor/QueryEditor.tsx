import { useRef, useCallback, useEffect, useState } from 'react';
import Editor, { BeforeMount, OnMount, OnChange } from '@monaco-editor/react';
import type { editor, IDisposable, KeyCode } from 'monaco-editor';
import { format as formatSql } from 'sql-formatter';
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

export interface QueryEditorRef {
  formatDocument: () => void;
}

interface QueryEditorProps {
  tabId: string;
  schemaMetadata?: SchemaMetadata | null;
  editorRef?: React.RefObject<QueryEditorRef | null>;
}

// Custom dark theme for Liquid Glass aesthetic
const PHAROS_DARK_THEME: editor.IStandaloneThemeData = {
  base: 'vs-dark',
  inherit: true,
  rules: [
    { token: 'keyword', foreground: '82AAFF' }, // Soft blue
    { token: 'keyword.sql', foreground: '82AAFF' },
    { token: 'string', foreground: 'C3E88D' }, // Soft green
    { token: 'string.sql', foreground: 'C3E88D' },
    { token: 'number', foreground: 'B5CEA8' }, // Sage green
    { token: 'comment', foreground: '6A7A8B', fontStyle: 'italic' }, // Muted slate
    { token: 'operator', foreground: '89DDFF' }, // Light cyan
    { token: 'identifier', foreground: 'D4D4D4' }, // Light gray
    { token: 'type', foreground: '4EC9B0' }, // Teal
    { token: 'predefined', foreground: 'DCDCAA' }, // Muted yellow
  ],
  colors: {
    'editor.background': '#1e1e1e',
    'editor.foreground': '#F8F8F2',
    'editor.lineHighlightBackground': '#2a2d2e',
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
    'editorSuggestWidget.background': '#252526',
    'editorSuggestWidget.border': '#454545',
    'editorSuggestWidget.foreground': '#CCCCCC',
    'editorSuggestWidget.highlightForeground': '#18A0FB',
    'editorSuggestWidget.selectedBackground': '#04395e',
    'editorSuggestWidget.selectedForeground': '#FFFFFF',
    'editorSuggestWidget.focusHighlightForeground': '#18A0FB',
    'editorStickyScroll.background': '#1e1e1e',
    'editorStickyScrollHover.background': '#2a2a2a',
    'minimap.background': '#1e1e1e',
  },
};

// Custom light theme
const PHAROS_LIGHT_THEME: editor.IStandaloneThemeData = {
  base: 'vs',
  inherit: true,
  rules: [
    { token: 'keyword', foreground: '0033B3' }, // Deep blue
    { token: 'keyword.sql', foreground: '0033B3' },
    { token: 'string', foreground: '067D17' }, // Forest green
    { token: 'string.sql', foreground: '067D17' },
    { token: 'number', foreground: '1750EB' }, // Bright blue
    { token: 'comment', foreground: '8C8C8C', fontStyle: 'italic' }, // Medium gray
    { token: 'operator', foreground: '1A1A1A' }, // Near black
    { token: 'identifier', foreground: '1A1A1A' }, // Near black for readability
    { token: 'type', foreground: '007068' }, // Dark cyan
    { token: 'predefined', foreground: '7A3E9D' }, // Rich purple
  ],
  colors: {
    'editor.background': '#ffffff',
    'editor.foreground': '#1A1A1A',
    'editor.lineHighlightBackground': '#f5f5f5',
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
    'editorSuggestWidget.background': '#FFFFFF',
    'editorSuggestWidget.border': '#C8C8C8',
    'editorSuggestWidget.foreground': '#333333',
    'editorSuggestWidget.highlightForeground': '#0066BF',
    'editorSuggestWidget.selectedBackground': '#0060C0',
    'editorSuggestWidget.selectedForeground': '#FFFFFF',
    'editorSuggestWidget.focusHighlightForeground': '#9DDDFF',
    'editorStickyScroll.background': '#F3F3F3',
    'editorStickyScrollHover.background': '#E8E8E8',
    'minimap.background': '#ffffff',
  },
};

// Debounce delay for validation (ms)
const VALIDATION_DEBOUNCE_MS = 500;

export function QueryEditor({ tabId, schemaMetadata, editorRef: externalEditorRef }: QueryEditorProps) {
  const editorRef = useRef<editor.IStandaloneCodeEditor | null>(null);
  const monacoRef = useRef<typeof import('monaco-editor') | null>(null);
  const completionProviderRef = useRef<IDisposable | null>(null);
  const foldingProviderRef = useRef<IDisposable | null>(null);
  const formattingProviderRef = useRef<IDisposable | null>(null);
  const schemaMetadataRef = useRef<SchemaMetadata | null>(null);
  const validationTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const tabIdRef = useRef(tabId);

  // Keep tabIdRef in sync with the current tabId prop
  useEffect(() => {
    tabIdRef.current = tabId;
  }, [tabId]);

  const tab = useEditorStore((state) => state.getTab(tabId));
  const updateTabSql = useEditorStore((state) => state.updateTabSql);
  const updateCursorPosition = useEditorStore((state) => state.updateCursorPosition);
  const setTabValidation = useEditorStore((state) => state.setTabValidation);
  const setTabValidating = useEditorStore((state) => state.setTabValidating);
  const activeConnection = useConnectionStore((state) => state.getActiveConnection());
  const activeConnectionId = useConnectionStore((state) => state.activeConnectionId);
  const selectedSchema = useConnectionStore((state) => state.getActiveSelectedSchema());
  const editorSettings = useSettingsStore((state) => state.settings.editor);
  // Track effective theme, including OS-level changes when theme is 'auto'
  const themeSetting = useSettingsStore((state) => state.settings.theme);
  const [effectiveTheme, setEffectiveTheme] = useState<'light' | 'dark'>(() => {
    if (themeSetting === 'auto') {
      return window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    }
    return themeSetting;
  });

  useEffect(() => {
    if (themeSetting !== 'auto') {
      setEffectiveTheme(themeSetting);
      return;
    }
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    setEffectiveTheme(mq.matches ? 'dark' : 'light');
    const handler = (e: MediaQueryListEvent) => setEffectiveTheme(e.matches ? 'dark' : 'light');
    mq.addEventListener('change', handler);
    return () => mq.removeEventListener('change', handler);
  }, [themeSetting]);

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

  // Define custom themes before the editor mounts so the theme prop works
  const handleEditorBeforeMount: BeforeMount = useCallback(
    (monaco) => {
      monaco.editor.defineTheme('pharos-dark', PHAROS_DARK_THEME);
      monaco.editor.defineTheme('pharos-light', PHAROS_LIGHT_THEME);
    },
    []
  );

  const handleEditorMount: OnMount = useCallback(
    (editor, monaco) => {
      editorRef.current = editor;
      monacoRef.current = monaco;

      // Register custom completion provider
      completionProviderRef.current = monaco.languages.registerCompletionItemProvider(
        'sql',
        createCompletionProvider(() => schemaMetadataRef.current)
      );

      // Register custom SQL folding range provider for SQL clauses
      foldingProviderRef.current = monaco.languages.registerFoldingRangeProvider('sql', {
        provideFoldingRanges(model: editor.ITextModel) {
          const ranges: { start: number; end: number; kind?: number }[] = [];
          const lineCount = model.getLineCount();

          // SQL keywords that start foldable sections
          const sectionKeywords = /^\s*(WITH|SELECT|FROM|WHERE|GROUP\s+BY|HAVING|ORDER\s+BY|LIMIT|UNION|INTERSECT|EXCEPT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|VALUES)\b/i;

          // Track parentheses for folding blocks like VALUES (...), subqueries, etc.
          const parenStack: { line: number; col: number }[] = [];

          // Track SQL section starts
          let currentSectionStart: number | null = null;

          for (let lineNum = 1; lineNum <= lineCount; lineNum++) {
            const lineContent = model.getLineContent(lineNum);

            // Check for SQL section keywords
            if (sectionKeywords.test(lineContent)) {
              // End previous section if exists and spans multiple lines
              if (currentSectionStart !== null && lineNum > currentSectionStart + 1) {
                ranges.push({
                  start: currentSectionStart,
                  end: lineNum - 1,
                  kind: monaco.languages.FoldingRangeKind.Region,
                });
              }
              currentSectionStart = lineNum;
            }

            // Track parentheses for multi-line blocks
            for (let i = 0; i < lineContent.length; i++) {
              const char = lineContent[i];
              if (char === '(') {
                parenStack.push({ line: lineNum, col: i });
              } else if (char === ')' && parenStack.length > 0) {
                const openParen = parenStack.pop()!;
                // Only create fold if parentheses span multiple lines
                if (lineNum > openParen.line) {
                  ranges.push({
                    start: openParen.line,
                    end: lineNum,
                    kind: monaco.languages.FoldingRangeKind.Region,
                  });
                }
              }
            }
          }

          // Close final section if it exists
          if (currentSectionStart !== null && lineCount > currentSectionStart) {
            ranges.push({
              start: currentSectionStart,
              end: lineCount,
              kind: monaco.languages.FoldingRangeKind.Region,
            });
          }

          return ranges;
        },
      });

      // Register SQL formatting provider
      formattingProviderRef.current = monaco.languages.registerDocumentFormattingEditProvider('sql', {
        provideDocumentFormattingEdits(model: editor.ITextModel) {
          const text = model.getValue();
          try {
            const formatted = formatSql(text, {
              language: 'postgresql',
              tabWidth: editorSettings.tabSize,
              useTabs: false,
              keywordCase: 'upper',
              dataTypeCase: 'upper',
              functionCase: 'lower',
            });
            return [{
              range: model.getFullModelRange(),
              text: formatted,
            }];
          } catch {
            return [];
          }
        },
      });

      // Track cursor position - use tabIdRef to always get the current tabId
      editor.onDidChangeCursorPosition((e) => {
        updateCursorPosition(tabIdRef.current, e.position.lineNumber, e.position.column);
      });

      // Set initial cursor position (important for newly mounted editors)
      const initialPosition = editor.getPosition();
      if (initialPosition) {
        updateCursorPosition(tabIdRef.current, initialPosition.lineNumber, initialPosition.column);
      }

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

        // For Escape key, use a context-aware keybinding that only triggers
        // when the suggest widget is NOT visible. This allows Escape to first
        // close autocomplete, and only cancel the query when autocomplete isn't showing.
        if (shortcut.key.toLowerCase() === 'escape' && shortcut.modifiers.length === 0) {
          editor.addAction({
            id: `pharos.${shortcutId}`,
            label: shortcut.label,
            keybindings: [keybinding],
            // Only trigger when suggest widget is not visible
            precondition: '!suggestWidgetVisible',
            run: () => {
              emitShortcutEvent(shortcutId);
            },
          });
        } else {
          // Register the shortcut to emit a custom event
          editor.addCommand(keybinding, () => {
            emitShortcutEvent(shortcutId);
          });
        }
      }

      // Focus the editor
      editor.focus();
    },
    [updateCursorPosition]
  );

  // Expose format method to parent via ref
  useEffect(() => {
    if (externalEditorRef && 'current' in externalEditorRef) {
      (externalEditorRef as React.MutableRefObject<QueryEditorRef | null>).current = {
        formatDocument: () => {
          if (editorRef.current) {
            editorRef.current.getAction('editor.action.formatDocument')?.run();
          }
        },
      };
    }
  }, [externalEditorRef]);

  // Explicitly set Monaco theme when effectiveTheme changes (safety net alongside theme prop)
  useEffect(() => {
    if (monacoRef.current) {
      monacoRef.current.editor.setTheme(effectiveTheme === 'dark' ? 'pharos-dark' : 'pharos-light');
    }
  }, [effectiveTheme]);

  // Cleanup providers and validation timeout on unmount
  useEffect(() => {
    return () => {
      if (completionProviderRef.current) {
        completionProviderRef.current.dispose();
      }
      if (foldingProviderRef.current) {
        foldingProviderRef.current.dispose();
      }
      if (formattingProviderRef.current) {
        formattingProviderRef.current.dispose();
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

  // Focus editor and update cursor position when tab becomes active
  useEffect(() => {
    if (editorRef.current) {
      editorRef.current.focus();
      // Update cursor position for the new tab
      const position = editorRef.current.getPosition();
      if (position) {
        updateCursorPosition(tabId, position.lineNumber, position.column);
      }
    }
  }, [tabId, updateCursorPosition]);

  if (!tab) {
    return null;
  }

  return (
    <div className="h-full w-full">
      <Editor
        height="100%"
        language="sql"
        value={tab.sql}
        theme={effectiveTheme === 'dark' ? 'pharos-dark' : 'pharos-light'}
        onChange={handleChange}
        beforeMount={handleEditorBeforeMount}
        onMount={handleEditorMount}
        options={{
          fontSize: editorSettings.fontSize,
          fontFamily: editorSettings.fontFamily,
          fontLigatures: false,
          minimap: { enabled: editorSettings.minimap },
          scrollBeyondLastLine: false,
          lineNumbers: editorSettings.lineNumbers ? 'on' : 'off',
          glyphMargin: false,
          folding: true,
          foldingStrategy: 'auto',
          showFoldingControls: 'always',
          lineDecorationsWidth: 10,
          lineNumbersMinChars: 3,
          renderLineHighlight: 'line',
          scrollbar: {
            vertical: 'auto',
            horizontal: 'auto',
            verticalScrollbarSize: 10,
            horizontalScrollbarSize: 10,
          },
          padding: { top: 10, bottom: 50 },
          contextmenu: true,
          quickSuggestions: true,
          suggestOnTriggerCharacters: true,
          acceptSuggestionOnEnter: 'on', // Accept suggestions with Enter or Tab
          acceptSuggestionOnCommitCharacter: false, // Don't accept on commit characters like space
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
