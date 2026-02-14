import { useCallback, useEffect, useState, useRef, useMemo } from 'react';
import { Play, Trash2, Square, Loader2, Save, PanelLeftClose, PanelLeft, CheckCircle2, XCircle, WandSparkles } from 'lucide-react';
import { cn } from '@/lib/cn';
import { QueryTabs } from '@/components/editor/QueryTabs';
import { QueryEditor, type QueryEditorRef } from '@/components/editor/QueryEditor';
import { ResultsGrid, ResultsGridRef } from '@/components/results/ResultsGrid';
import { ExplainView } from '@/components/results/ExplainView';
import { SaveQueryDialog } from '@/components/dialogs/SaveQueryDialog';
import { ExportResultsDialog } from '@/components/dialogs/ExportResultsDialog';
import { SavedQueriesPanel } from '@/components/saved/SavedQueriesPanel';
import { QueryHistoryPanel } from '@/components/history/QueryHistoryPanel';
import { useConnectionStore } from '@/stores/connectionStore';
import { useEditorStore } from '@/stores/editorStore';
import { useQueryHistoryStore } from '@/stores/queryHistoryStore';
import { useSettingsStore } from '@/stores/settingsStore';
import { useKeyboardShortcuts } from '@/hooks/useKeyboardShortcuts';
import * as tauri from '@/lib/tauri';
import type { SavedQuery, TableInfo, ColumnInfo, QueryHistoryEntry } from '@/lib/types';
import type { SchemaMetadata } from '@/components/editor/SqlAutocomplete';

interface QueryWorkspaceProps {
  isResultsExpanded?: boolean;
  onToggleResultsExpand?: () => void;
}

export function QueryWorkspace({ isResultsExpanded, onToggleResultsExpand }: QueryWorkspaceProps) {
  const activeConnection = useConnectionStore((state) => state.getActiveConnection());
  const activeConnectionId = useConnectionStore((state) => state.activeConnectionId);
  const selectedSchema = useConnectionStore((state) => state.getActiveSelectedSchema());
  const isConnected = activeConnection?.status === 'connected';

  const tabs = useEditorStore((state) => state.tabs);
  const activeTabId = useEditorStore((state) => state.activeTabId);
  // Use direct selector instead of getter function to ensure reactivity
  // Select specific fields individually to ensure proper re-rendering
  const activeTab = useEditorStore((state) =>
    state.activeTabId ? state.tabs.find(t => t.id === state.activeTabId) : undefined
  );
  // Select cursorPosition separately to ensure re-renders when it changes
  const cursorPosition = useEditorStore((state) => {
    const tab = state.activeTabId ? state.tabs.find(t => t.id === state.activeTabId) : undefined;
    return tab?.cursorPosition;
  });
  const createTab = useEditorStore((state) => state.createTab);
  const setTabExecuting = useEditorStore((state) => state.setTabExecuting);
  const setTabResults = useEditorStore((state) => state.setTabResults);
  const setTabError = useEditorStore((state) => state.setTabError);
  const clearTabResults = useEditorStore((state) => state.clearTabResults);

  const createTabWithContent = useEditorStore((state) => state.createTabWithContent);
  const closeTab = useEditorStore((state) => state.closeTab);
  const setActiveTab = useEditorStore((state) => state.setActiveTab);
  const pinnedResultsTabId = useEditorStore((state) => state.pinnedResultsTabId);
  const pinResults = useEditorStore((state) => state.pinResults);
  const unpinResults = useEditorStore((state) => state.unpinResults);
  const setTabEditableInfo = useEditorStore((state) => state.setTabEditableInfo);
  const addPendingEdit = useEditorStore((state) => state.addPendingEdit);
  const clearPendingEdits = useEditorStore((state) => state.clearPendingEdits);

  const prependHistoryEntry = useQueryHistoryStore((state) => state.prependEntry);
  const updateHistoryEntry = useQueryHistoryStore((state) => state.updateEntry);

  // Determine which tab's results to display (pinned tab takes precedence)
  const displayTab = pinnedResultsTabId
    ? tabs.find((t) => t.id === pinnedResultsTabId)
    : activeTab;

  // UI layout settings from persisted store
  const uiSettings = useSettingsStore((state) => state.settings.ui);
  const updateUISettings = useSettingsStore((state) => state.updateUISettings);
  const settings = useSettingsStore((state) => state.settings);
  const isSettingsLoaded = useSettingsStore((state) => state.isLoaded);

  // Local state derived from persisted settings (with defaults for missing values)
  const DEFAULT_SPLIT_POSITION = 40;
  const DEFAULT_LIBRARY_WIDTH = 180;

  const [splitPosition, setSplitPosition] = useState(uiSettings.editorSplitPosition ?? DEFAULT_SPLIT_POSITION);
  const [libraryWidth, setLibraryWidth] = useState(uiSettings.savedQueriesWidth ?? DEFAULT_LIBRARY_WIDTH);
  const hasInitializedFromSettings = useRef(false);

  // Sync local state when settings are loaded from disk
  useEffect(() => {
    if (isSettingsLoaded && !hasInitializedFromSettings.current) {
      hasInitializedFromSettings.current = true;
      // Use nullish coalescing to handle missing fields from older settings files
      setSplitPosition(uiSettings.editorSplitPosition ?? DEFAULT_SPLIT_POSITION);
      setLibraryWidth(uiSettings.savedQueriesWidth ?? DEFAULT_LIBRARY_WIDTH);
    }
  }, [isSettingsLoaded, uiSettings.editorSplitPosition, uiSettings.savedQueriesWidth]);

  const pushClosedTab = useEditorStore((state) => state.pushClosedTab);
  const popClosedTab = useEditorStore((state) => state.popClosedTab);
  const resultsRef = useRef<ResultsGridRef>(null);
  const queryEditorRef = useRef<QueryEditorRef>(null);
  const [isResizing, setIsResizing] = useState(false);
  const [showSaveDialog, setShowSaveDialog] = useState(false);
  const [showExportDialog, setShowExportDialog] = useState(false);
  const [showQueryLibrary, setShowQueryLibrary] = useState(true);
  const [isResizingLibrary, setIsResizingLibrary] = useState(false);
  const [activePanel, setActivePanel] = useState<'saved' | 'history'>('saved');
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);

  // Schema metadata for autocomplete
  const [schemaMetadata, setSchemaMetadata] = useState<SchemaMetadata | null>(null);

  // Debounced save for UI settings
  const saveTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Persist layout changes with debouncing (only after initial load)
  useEffect(() => {
    // Don't save until settings have been loaded and initialized
    if (!hasInitializedFromSettings.current) return;

    if (saveTimeoutRef.current) {
      clearTimeout(saveTimeoutRef.current);
    }
    saveTimeoutRef.current = setTimeout(() => {
      // Only save if values have changed from stored settings
      if (
        splitPosition !== uiSettings.editorSplitPosition ||
        libraryWidth !== uiSettings.savedQueriesWidth
      ) {
        updateUISettings({
          editorSplitPosition: splitPosition,
          savedQueriesWidth: libraryWidth,
        });
        // Save to disk
        tauri.saveSettings({
          ...settings,
          ui: {
            ...settings.ui,
            editorSplitPosition: splitPosition,
            savedQueriesWidth: libraryWidth,
          },
        });
      }
    }, 500);

    return () => {
      if (saveTimeoutRef.current) {
        clearTimeout(saveTimeoutRef.current);
      }
    };
  }, [splitPosition, libraryWidth, uiSettings.editorSplitPosition, uiSettings.savedQueriesWidth, updateUISettings, settings]);

  useEffect(() => {
    if (isConnected && tabs.length === 0 && activeConnectionId) {
      createTab(activeConnectionId);
    }
  }, [isConnected, tabs.length, activeConnectionId, createTab]);

  // Load schema metadata for autocomplete when connected or selected schema changes
  useEffect(() => {
    if (!isConnected || !activeConnectionId) {
      setSchemaMetadata(null);
      return;
    }

    const loadMetadata = async () => {
      try {
        // Load schemas
        const schemas = await tauri.getSchemas(activeConnectionId);

        // Determine which schemas to load tables/columns for
        const schemasToLoad = selectedSchema
          ? schemas.filter(s => s.name === selectedSchema)
          : schemas;

        const tables = new Map<string, TableInfo[]>();
        const columns = new Map<string, ColumnInfo[]>();

        // Load tables and columns for relevant schemas
        for (const schema of schemasToLoad) {
          const schemaTables = await tauri.getTables(activeConnectionId, schema.name);
          tables.set(schema.name, schemaTables);

          // Load columns for each table
          for (const table of schemaTables) {
            const tableColumns = await tauri.getColumns(activeConnectionId, schema.name, table.name);
            columns.set(`${schema.name}.${table.name}`, tableColumns);
          }
        }

        setSchemaMetadata({ schemas, tables, columns });
      } catch (err) {
        console.error('Failed to load schema metadata for autocomplete:', err);
        setSchemaMetadata(null);
      }
    };

    loadMetadata();
  }, [isConnected, activeConnectionId, selectedSchema]);

  const handleExecute = useCallback(async () => {
    if (!activeTab || !activeConnectionId || !isConnected) return;

    const sql = activeTab.sql.trim();
    if (!sql) return;

    // Unpin any pinned results so the new query results are visible
    unpinResults();

    const queryId = `query-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
    setTabExecuting(activeTab.id, true, queryId);

    try {
      // Detect EXPLAIN queries and inject FORMAT JSON if not already specified
      const isExplain = /^\s*EXPLAIN\b/i.test(sql);
      let execSql = sql;
      if (isExplain) {
        // Check if FORMAT is already specified
        const hasFormat = /EXPLAIN\s*\([^)]*FORMAT\b/i.test(sql);
        if (!hasFormat) {
          // EXPLAIN (...) SELECT  or  EXPLAIN SELECT
          const parenMatch = sql.match(/^(\s*EXPLAIN\s*\()([^)]*)\)/i);
          if (parenMatch) {
            // Already has options in parens — add FORMAT JSON
            execSql = sql.replace(
              /^(\s*EXPLAIN\s*\()([^)]*)\)/i,
              `$1$2, FORMAT JSON)`
            );
          } else {
            // Check for shorthand options like EXPLAIN ANALYZE, EXPLAIN VERBOSE, etc.
            // These need to go inside parentheses: EXPLAIN (ANALYZE, VERBOSE, FORMAT JSON)
            const shorthandMatch = sql.match(/^\s*EXPLAIN\s+((?:(?:ANALYZE|VERBOSE)\s+)*)/i);
            if (shorthandMatch && shorthandMatch[1].trim().length > 0) {
              // Convert shorthand options to parenthesized form
              const opts = shorthandMatch[1].trim().replace(/\s+/g, ', ');
              execSql = sql.replace(
                /^\s*EXPLAIN\s+(?:(?:ANALYZE|VERBOSE)\s+)*/i,
                `EXPLAIN (${opts}, FORMAT JSON) `
              );
            } else {
              // Simple EXPLAIN SELECT — wrap with (FORMAT JSON)
              execSql = sql.replace(
                /^(\s*EXPLAIN)\s+/i,
                '$1 (FORMAT JSON) '
              );
            }
          }
        }
      }

      // Pass the selected schema to set search_path before executing
      const limit = settings.query.defaultLimit;
      const result = await tauri.executeQuery(activeConnectionId, execSql, queryId, limit, selectedSchema);

      // Parse EXPLAIN JSON output if applicable
      let explainPlan: import('@/lib/types').ExplainPlanNode[] | undefined;
      let explainRawJson: string | undefined;
      if (isExplain && result.rows.length > 0) {
        try {
          // PostgreSQL returns EXPLAIN JSON as a single row with a single column
          const firstCol = result.columns[0]?.name;
          const rawValue = firstCol ? result.rows[0][firstCol] : null;
          const jsonStr = typeof rawValue === 'string' ? rawValue : JSON.stringify(rawValue);
          const parsed = JSON.parse(jsonStr);
          // PostgreSQL wraps the plan in an array of objects with a "Plan" key
          const planArray = Array.isArray(parsed) ? parsed : [parsed];
          explainPlan = planArray.map((entry: Record<string, unknown>) =>
            (entry['Plan'] ?? entry) as import('@/lib/types').ExplainPlanNode
          );
          explainRawJson = JSON.stringify(parsed, null, 2);
        } catch {
          // If parsing fails, just show as regular results
        }
      }

      setTabResults(
        activeTab.id,
        {
          columns: result.columns.map((c) => ({
            name: c.name,
            dataType: c.data_type,
          })),
          rows: result.rows,
          rowCount: result.row_count,
          hasMore: result.has_more,
          historyEntryId: result.history_entry_id,
          explainPlan,
          explainRawJson,
        },
        result.execution_time_ms
      );

      // Prepend new entry to history store so the History tab updates live
      if (result.history_entry_id) {
        prependHistoryEntry({
          id: result.history_entry_id,
          connectionId: activeConnectionId,
          connectionName: activeConnection?.config.name ?? activeConnectionId,
          sql,
          rowCount: result.row_count,
          executionTimeMs: result.execution_time_ms,
          executedAt: new Date().toISOString(),
          hasResults: result.rows.length > 0,
        });
      }

      // Fire-and-forget editability check for non-EXPLAIN queries
      if (!isExplain && result.rows.length > 0) {
        const tabId = activeTab.id;
        const connId = activeConnectionId;
        tauri.checkQueryEditable(connId, sql, selectedSchema ?? undefined).then((info) => {
          setTabEditableInfo(tabId, info);
        }).catch((err) => {
          console.error('Editability check failed:', err);
          setTabEditableInfo(tabId, null);
        });
      }
    } catch (err) {
      setTabError(activeTab.id, err instanceof Error ? err.message : String(err));
    }
  }, [activeTab, activeConnection, activeConnectionId, isConnected, selectedSchema, settings.query.defaultLimit, unpinResults, setTabExecuting, setTabResults, setTabError, setTabEditableInfo, prependHistoryEntry]);

  const handleCancel = useCallback(async () => {
    if (!activeTab || !activeConnectionId || !activeTab.queryId) return;

    try {
      await tauri.cancelQuery(activeConnectionId, activeTab.queryId);
    } catch (err) {
      console.error('Failed to cancel query:', err);
    }
  }, [activeTab, activeConnectionId]);

  const handleClear = useCallback(() => {
    if (activeTab) {
      clearTabResults(activeTab.id);
    }
  }, [activeTab, clearTabResults]);

  const handleMouseDown = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    setIsResizing(true);
  }, []);

  useEffect(() => {
    if (!isResizing) return;

    const handleMouseMove = (e: MouseEvent) => {
      if (!containerRef.current) return;
      const rect = containerRef.current.getBoundingClientRect();
      const fromTop = ((e.clientY - rect.top) / rect.height) * 100;
      setSplitPosition(Math.round(Math.max(20, Math.min(80, 100 - fromTop))));
    };

    const handleMouseUp = () => {
      setIsResizing(false);
    };

    document.addEventListener('mousemove', handleMouseMove);
    document.addEventListener('mouseup', handleMouseUp);

    return () => {
      document.removeEventListener('mousemove', handleMouseMove);
      document.removeEventListener('mouseup', handleMouseUp);
    };
  }, [isResizing]);

  const handleCellEdit = useCallback((rowIndex: number, columnName: string, newValue: unknown) => {
    if (!activeTab || !displayTab?.results) return;
    const originalRow = displayTab.results.rows[rowIndex];
    if (!originalRow) return;
    addPendingEdit(activeTab.id, {
      type: 'update',
      rowIndex,
      changes: { [columnName]: newValue },
      originalRow,
    });
  }, [activeTab, displayTab, addPendingEdit]);

  const handleDeleteRows = useCallback((rowIndices: number[]) => {
    if (!activeTab || !displayTab?.results) return;
    for (const rowIndex of rowIndices) {
      const originalRow = displayTab.results.rows[rowIndex];
      if (!originalRow) continue;
      addPendingEdit(activeTab.id, {
        type: 'delete',
        rowIndex,
        changes: {},
        originalRow,
      });
    }
  }, [activeTab, displayTab, addPendingEdit]);

  const handleCommitEdits = useCallback(async () => {
    if (!activeTab || !activeConnectionId || !displayTab?.editableInfo || !displayTab?.pendingEdits?.length) return;
    const { schemaName, tableName, primaryKeys } = displayTab.editableInfo;
    try {
      const result = await tauri.commitDataEdits(activeConnectionId, {
        schemaName,
        tableName,
        primaryKeys,
        edits: displayTab.pendingEdits,
      });
      if (result.success) {
        clearPendingEdits(activeTab.id);
        // Re-run the query to refresh data
        // Trigger execute by creating a small delay then calling handleExecute indirectly
        // Instead, just clear and let user re-run if they want fresh data
      } else {
        setTabError(activeTab.id, `Commit failed: ${result.errors.join(', ')}`);
      }
    } catch (err) {
      setTabError(activeTab.id, err instanceof Error ? err.message : String(err));
    }
  }, [activeTab, activeConnectionId, displayTab, clearPendingEdits, setTabError]);

  const handleDiscardEdits = useCallback(() => {
    if (activeTab) {
      clearPendingEdits(activeTab.id);
    }
  }, [activeTab, clearPendingEdits]);

  const handleSave = useCallback(() => {
    if (activeTab?.sql.trim()) {
      setShowSaveDialog(true);
    }
  }, [activeTab?.sql]);

  const handleCloseTab = useCallback(() => {
    if (activeTab) {
      pushClosedTab({ name: activeTab.name, sql: activeTab.sql });
      closeTab(activeTab.id);
    }
  }, [activeTab, closeTab, pushClosedTab]);

  const handleReopenTab = useCallback(() => {
    const last = popClosedTab();
    if (last && activeConnectionId) {
      createTabWithContent(activeConnectionId, last.name, last.sql, null);
    }
  }, [popClosedTab, activeConnectionId, createTabWithContent]);

  const handleNextTab = useCallback(() => {
    const currentIndex = tabs.findIndex((t) => t.id === activeTabId);
    const nextIndex = (currentIndex + 1) % tabs.length;
    if (tabs[nextIndex]) setActiveTab(tabs[nextIndex].id);
  }, [tabs, activeTabId, setActiveTab]);

  const handlePrevTab = useCallback(() => {
    const currentIndex = tabs.findIndex((t) => t.id === activeTabId);
    const prevIndex = currentIndex <= 0 ? tabs.length - 1 : currentIndex - 1;
    if (tabs[prevIndex]) setActiveTab(tabs[prevIndex].id);
  }, [tabs, activeTabId, setActiveTab]);

  const handleCopyResults = useCallback(() => {
    resultsRef.current?.copyToClipboard();
  }, []);

  const handleExport = useCallback(() => {
    setShowExportDialog(true);
  }, []);

  const handleLoadMore = useCallback(async () => {
    // Use displayTab (which may be pinned) to get the current results
    const tab = displayTab;
    if (!tab?.results || !tab.connectionId || !tab.results.hasMore || isLoadingMore) return;

    setIsLoadingMore(true);
    try {
      const limit = settings.query.defaultLimit;
      const currentRows = tab.results.rows;
      const result = await tauri.fetchMoreRows(
        tab.connectionId,
        tab.sql,
        limit,
        currentRows.length,
        selectedSchema
      );

      // Merge new rows into existing results
      const mergedRows = [...currentRows, ...result.rows as Record<string, unknown>[]];
      const historyEntryId = tab.results.historyEntryId;

      setTabResults(tab.id, {
        columns: tab.results.columns,
        rows: mergedRows,
        rowCount: mergedRows.length,
        hasMore: result.has_more,
        historyEntryId,
      }, tab.executionTime);

      // Fire-and-forget: update cached history results and store entry
      if (historyEntryId) {
        updateHistoryEntry(historyEntryId, { rowCount: mergedRows.length });
        const columnsJson = JSON.stringify(
          tab.results.columns.map((c) => ({ name: c.name, data_type: c.dataType }))
        );
        const rowsJson = JSON.stringify(mergedRows);
        tauri.updateQueryHistoryResults(historyEntryId, mergedRows.length, columnsJson, rowsJson)
          .catch((err) => console.error('Failed to update history results:', err));
      }
    } catch (err) {
      console.error('Failed to load more rows:', err);
    } finally {
      setIsLoadingMore(false);
    }
  }, [displayTab, selectedSchema, settings.query.defaultLimit, isLoadingMore, setTabResults, updateHistoryEntry]);

  const handleFormat = useCallback(() => {
    queryEditorRef.current?.formatDocument();
  }, []);

  // Memoize handlers to prevent re-creating on every render
  // Only register query.cancel when a query is running, so bare Escape
  // doesn't get consumed and can reach ResultsGrid for deselection
  const shortcutHandlers = useMemo(
    () => ({
      'query.run': handleExecute,
      'query.save': handleSave,
      ...(activeTab?.isExecuting ? { 'query.cancel': handleCancel } : {}),
      'tab.new': () => activeConnectionId && createTab(activeConnectionId),
      'tab.close': handleCloseTab,
      'tab.reopen': handleReopenTab,
      'tab.next': handleNextTab,
      'tab.prev': handlePrevTab,
      'tab.1': () => tabs[0] && setActiveTab(tabs[0].id),
      'tab.2': () => tabs[1] && setActiveTab(tabs[1].id),
      'tab.3': () => tabs[2] && setActiveTab(tabs[2].id),
      'tab.4': () => tabs[3] && setActiveTab(tabs[3].id),
      'tab.5': () => tabs[4] && setActiveTab(tabs[4].id),
      'tab.6': () => tabs[5] && setActiveTab(tabs[5].id),
      'tab.7': () => tabs[6] && setActiveTab(tabs[6].id),
      'tab.8': () => tabs[7] && setActiveTab(tabs[7].id),
      'tab.9': () => tabs[tabs.length - 1] && setActiveTab(tabs[tabs.length - 1].id),
      'results.copy': handleCopyResults,
      'results.export': handleExport,
    }),
    [
      handleExecute,
      handleSave,
      handleCancel,
      handleCloseTab,
      handleReopenTab,
      handleNextTab,
      handlePrevTab,
      handleCopyResults,
      handleExport,
      activeConnectionId,
      activeTab?.isExecuting,
      createTab,
      tabs,
      setActiveTab,
    ]
  );

  useKeyboardShortcuts(shortcutHandlers);

  const handleQuerySelect = useCallback(
    (query: SavedQuery) => {
      createTabWithContent(activeConnectionId, query.name, query.sql, query.id);
    },
    [activeConnectionId, createTabWithContent]
  );

  const handleHistorySelect = useCallback(
    async (entry: QueryHistoryEntry) => {
      const tabId = createTabWithContent(activeConnectionId, 'Query', entry.sql, null);

      // Load cached results if available
      if (entry.hasResults) {
        try {
          const cached = await tauri.getQueryHistoryResult(entry.id);
          if (cached) {
            setTabResults(
              tabId,
              {
                columns: cached.columns.map((c: { name: string; data_type: string }) => ({
                  name: c.name,
                  dataType: c.data_type,
                })),
                rows: cached.rows,
                rowCount: cached.rows.length,
                hasMore: false,
              },
              entry.executionTimeMs
            );
          }
        } catch (err) {
          console.error('Failed to load cached results:', err);
        }
      }
    },
    [activeConnectionId, createTabWithContent, setTabResults]
  );

  const libraryResizeStartX = useRef(0);
  const libraryResizeStartWidth = useRef(0);

  const handleLibraryMouseDown = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    libraryResizeStartX.current = e.clientX;
    libraryResizeStartWidth.current = libraryWidth;
    setIsResizingLibrary(true);
  }, [libraryWidth]);

  useEffect(() => {
    if (!isResizingLibrary) return;

    const handleMouseMove = (e: MouseEvent) => {
      const delta = e.clientX - libraryResizeStartX.current;
      const newWidth = Math.round(Math.max(140, Math.min(500, libraryResizeStartWidth.current + delta)));
      setLibraryWidth(newWidth);
    };

    const handleMouseUp = () => {
      setIsResizingLibrary(false);
    };

    document.addEventListener('mousemove', handleMouseMove);
    document.addEventListener('mouseup', handleMouseUp);

    return () => {
      document.removeEventListener('mousemove', handleMouseMove);
      document.removeEventListener('mouseup', handleMouseUp);
    };
  }, [isResizingLibrary]);

  return (
    <div className="h-full w-full flex flex-col bg-theme-bg-primary overflow-hidden" ref={containerRef}>
      {/* Top section: Results pane - full height when expanded */}
      <div
        className="bg-theme-bg-primary overflow-hidden min-w-0 flex-1"
        style={isResultsExpanded ? undefined : { height: `${100 - splitPosition}%`, flex: 'none' }}
      >
        {displayTab?.results?.explainPlan ? (
          <ExplainView
            plan={displayTab.results.explainPlan}
            rawJson={displayTab.results.explainRawJson ?? ''}
            executionTime={displayTab?.executionTime ?? null}
          />
        ) : (
          <ResultsGrid
            ref={resultsRef}
            results={displayTab?.results ?? null}
            error={displayTab?.error ?? null}
            executionTime={displayTab?.executionTime ?? null}
            isExecuting={displayTab?.isExecuting ?? false}
            isPinned={!!pinnedResultsTabId}
            pinnedTabName={displayTab?.name}
            canPin={!!activeTab?.results}
            onPin={() => activeTab && pinResults(activeTab.id)}
            onUnpin={unpinResults}
            isExpanded={isResultsExpanded}
            onToggleExpand={onToggleResultsExpand}
            onLoadMore={handleLoadMore}
            isLoadingMore={isLoadingMore}
            editableInfo={displayTab?.editableInfo ?? undefined}
            pendingEdits={displayTab?.pendingEdits}
            onCellEdit={handleCellEdit}
            onDeleteRows={handleDeleteRows}
            onCommitEdits={handleCommitEdits}
            onDiscardEdits={handleDiscardEdits}
            onExport={handleExport}
          />
        )}
      </div>

      {/* Resize handle - full width - hidden when expanded */}
      {!isResultsExpanded && (
      <div
        onMouseDown={handleMouseDown}
        className={cn(
          'h-1 cursor-row-resize flex-shrink-0 transition-colors',
          isResizing ? 'bg-theme-bg-active' : 'hover:bg-theme-bg-hover'
        )}
      />
      )}

      {/* Bottom section: Saved Queries + Editor - hidden when results are expanded */}
      {!isResultsExpanded && (
      <div className="flex flex-col min-h-0 overflow-hidden" style={{ height: `${splitPosition}%` }}>
        {/* Unified toolbar bar */}
        <div className="flex items-center px-2.5 py-1.5 border-b border-theme-border-subtle flex-shrink-0 bg-theme-bg-surface gap-1.5">
          {/* Library toggle */}
          <button
            onClick={() => setShowQueryLibrary(!showQueryLibrary)}
            className={cn(
              'p-1.5 rounded-lg hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary transition-colors',
              showQueryLibrary && 'text-theme-text-primary'
            )}
            title={showQueryLibrary ? 'Hide query library' : 'Show query library'}
          >
            {showQueryLibrary ? <PanelLeftClose className="w-4 h-4" /> : <PanelLeft className="w-4 h-4" />}
          </button>

          {/* Saved / History segmented control */}
          {showQueryLibrary && (
            <div className="flex items-center p-0.5 rounded-lg bg-theme-bg-hover">
              <button
                onClick={() => setActivePanel('saved')}
                className={cn(
                  'px-2.5 py-0.5 rounded-md text-xs font-medium transition-colors',
                  activePanel === 'saved'
                    ? 'text-theme-text-primary bg-theme-bg-elevated shadow-sm'
                    : 'text-theme-text-tertiary hover:text-theme-text-secondary'
                )}
              >
                Saved
              </button>
              <button
                onClick={() => setActivePanel('history')}
                className={cn(
                  'px-2.5 py-0.5 rounded-md text-xs font-medium transition-colors',
                  activePanel === 'history'
                    ? 'text-theme-text-primary bg-theme-bg-elevated shadow-sm'
                    : 'text-theme-text-tertiary hover:text-theme-text-secondary'
                )}
              >
                History
              </button>
            </div>
          )}

          {/* Separator */}
          <div className="w-px h-5 bg-theme-border-secondary mx-0.5" />

          {/* Query actions */}
          <button
            onClick={handleExecute}
            disabled={!isConnected || activeTab?.isExecuting}
            className={cn(
              'flex items-center gap-2 px-4 py-1.5 rounded-full text-sm font-medium transition-all duration-200',
              'bg-theme-accent-green hover:bg-theme-accent-green-hover text-white shadow-sm',
              'disabled:opacity-40 disabled:cursor-not-allowed'
            )}
          >
            {activeTab?.isExecuting ? (
              <>
                <Loader2 className="w-4 h-4 animate-spin" />
                Running...
              </>
            ) : (
              <>
                <Play className="w-4 h-4" />
                Run Query
              </>
            )}
          </button>
          {activeTab?.isExecuting && (
            <button
              onClick={handleCancel}
              className="p-1.5 rounded-lg hover:bg-theme-bg-hover text-red-400 hover:text-red-300 transition-colors"
              title="Cancel query"
            >
              <Square className="w-4 h-4" />
            </button>
          )}
          <button
            onClick={handleClear}
            className="p-1.5 rounded-lg hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary transition-colors disabled:opacity-40"
            disabled={!activeTab?.results && !activeTab?.error}
            title="Clear results"
          >
            <Trash2 className="w-4 h-4" />
          </button>
          <button
            onClick={handleSave}
            className="p-1.5 rounded-lg hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary transition-colors disabled:opacity-40"
            disabled={!activeTab?.sql.trim()}
            title="Save query (Cmd+S)"
          >
            <Save className="w-4 h-4" />
          </button>
          <button
            onClick={handleFormat}
            className="p-1.5 rounded-lg hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary transition-colors disabled:opacity-40"
            disabled={!activeTab?.sql.trim()}
            title="Format SQL (Shift+Alt+F)"
          >
            <WandSparkles className="w-4 h-4" />
          </button>

          <div className="flex-1" />

          <div className="text-xs text-theme-text-tertiary flex items-center gap-3">
            {cursorPosition && (
              <span>
                Ln {cursorPosition.line}, Col {cursorPosition.column}
              </span>
            )}
            {isConnected && activeTab && (
              <div className="flex items-center gap-1.5">
                {activeTab.validation.isValidating ? (
                  <span className="flex items-center gap-1 text-theme-text-muted">
                    <Loader2 className="w-3.5 h-3.5 animate-spin" />
                  </span>
                ) : activeTab.validation.isValid ? (
                  activeTab.sql.trim() ? (
                    <span className="flex items-center gap-1 text-emerald-500">
                      <CheckCircle2 className="w-3.5 h-3.5" />
                    </span>
                  ) : null
                ) : (
                  <span
                    className="flex items-center gap-1 text-red-400 cursor-help max-w-[200px]"
                    title={activeTab.validation.error?.message || 'SQL error'}
                  >
                    <XCircle className="w-3.5 h-3.5 flex-shrink-0" />
                    <span className="truncate text-[11px]">
                      {activeTab.validation.error?.message || 'SQL error'}
                    </span>
                  </span>
                )}
              </div>
            )}
          </div>
        </div>

        {/* Content area: sidebar + editor */}
        <div className="flex flex-1 min-h-0 overflow-hidden">
          {/* Query Library Sidebar */}
          {showQueryLibrary && (
            <div
              className="flex flex-col bg-theme-bg-sidebar border-r border-theme-border-subtle relative flex-shrink-0"
              style={{ width: libraryWidth }}
            >
              <div className="flex-1 overflow-hidden">
                {activePanel === 'saved' ? (
                  <SavedQueriesPanel onQuerySelect={handleQuerySelect} />
                ) : (
                  <QueryHistoryPanel connectionId={activeConnectionId ?? undefined} onQuerySelect={handleHistorySelect} />
                )}
              </div>
              {/* Resize handle */}
              <div
                onMouseDown={handleLibraryMouseDown}
                className={cn(
                  'absolute right-0 top-0 bottom-0 w-1 cursor-col-resize transition-colors',
                  'hover:bg-theme-bg-active',
                  isResizingLibrary && 'bg-theme-bg-active'
                )}
              />
            </div>
          )}

          {/* Editor Area */}
          <div className="flex-1 flex flex-col min-w-0">
            {/* Tabs */}
            <QueryTabs />

            {/* Editor pane */}
            <div className="flex-1 bg-theme-bg-primary overflow-hidden">
              {activeTabId ? (
                <QueryEditor tabId={activeTabId} schemaMetadata={schemaMetadata} editorRef={queryEditorRef} />
              ) : (
                <div className="h-full flex items-center justify-center text-theme-text-muted text-sm">
                  {isConnected
                    ? 'Click + to create a new query tab'
                    : 'Connect to a database to start writing queries'}
                </div>
              )}
            </div>
          </div>
        </div>
      </div>
      )}

      {/* Save Query Dialog */}
      <SaveQueryDialog
        isOpen={showSaveDialog}
        onClose={() => setShowSaveDialog(false)}
        sql={activeTab?.sql || ''}
        initialName={activeTab?.name || ''}
        existingSavedQueryId={activeTab?.savedQueryId ?? undefined}
      />

      {/* Export Results Dialog */}
      <ExportResultsDialog
        isOpen={showExportDialog}
        onClose={() => setShowExportDialog(false)}
        connectionId={displayTab?.connectionId ?? ''}
        sql={displayTab?.sql ?? ''}
        schema={selectedSchema ?? null}
        results={displayTab?.results ?? null}
      />
    </div>
  );
}
