import { useCallback, useEffect, useState, useRef, useMemo } from 'react';
import { Play, Trash2, Square, Loader2, Save, PanelLeftClose, PanelLeft, CheckCircle2, XCircle } from 'lucide-react';
import { cn } from '@/lib/cn';
import { QueryTabs } from '@/components/editor/QueryTabs';
import { QueryEditor } from '@/components/editor/QueryEditor';
import { ResultsGrid, ResultsGridRef } from '@/components/results/ResultsGrid';
import { SaveQueryDialog } from '@/components/dialogs/SaveQueryDialog';
import { SavedQueriesPanel } from '@/components/saved/SavedQueriesPanel';
import { useConnectionStore } from '@/stores/connectionStore';
import { useEditorStore } from '@/stores/editorStore';
import { useKeyboardShortcuts } from '@/hooks/useKeyboardShortcuts';
import * as tauri from '@/lib/tauri';
import type { SavedQuery } from '@/lib/types';

export function QueryWorkspace() {
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

  const [splitPosition, setSplitPosition] = useState(40);
  const [closedTabs, setClosedTabs] = useState<Array<{ name: string; sql: string }>>([]);
  const resultsRef = useRef<ResultsGridRef>(null);
  const [isResizing, setIsResizing] = useState(false);
  const [showSaveDialog, setShowSaveDialog] = useState(false);
  const [showQueryLibrary, setShowQueryLibrary] = useState(true);
  const [libraryWidth, setLibraryWidth] = useState(180);
  const [isResizingLibrary, setIsResizingLibrary] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (isConnected && tabs.length === 0 && activeConnectionId) {
      createTab(activeConnectionId);
    }
  }, [isConnected, tabs.length, activeConnectionId, createTab]);

  const handleExecute = useCallback(async () => {
    if (!activeTab || !activeConnectionId || !isConnected) return;

    const sql = activeTab.sql.trim();
    if (!sql) return;

    const queryId = `query-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
    setTabExecuting(activeTab.id, true, queryId);

    try {
      // Pass the selected schema to set search_path before executing
      const result = await tauri.executeQuery(activeConnectionId, sql, queryId, undefined, selectedSchema);

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
        },
        result.execution_time_ms
      );
    } catch (err) {
      setTabError(activeTab.id, err instanceof Error ? err.message : String(err));
    }
  }, [activeTab, activeConnectionId, isConnected, selectedSchema, setTabExecuting, setTabResults, setTabError]);

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
      const newPosition = ((e.clientY - rect.top) / rect.height) * 100;
      setSplitPosition(Math.max(20, Math.min(80, newPosition)));
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

  const handleSave = useCallback(() => {
    if (activeTab?.sql.trim()) {
      setShowSaveDialog(true);
    }
  }, [activeTab?.sql]);

  const handleCloseTab = useCallback(() => {
    if (activeTab) {
      setClosedTabs((prev) => [...prev.slice(-9), { name: activeTab.name, sql: activeTab.sql }]);
      closeTab(activeTab.id);
    }
  }, [activeTab, closeTab]);

  const handleReopenTab = useCallback(() => {
    const last = closedTabs[closedTabs.length - 1];
    if (last && activeConnectionId) {
      setClosedTabs((prev) => prev.slice(0, -1));
      createTabWithContent(activeConnectionId, last.name, last.sql, false);
    }
  }, [closedTabs, activeConnectionId, createTabWithContent]);

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

  const handleExportCSV = useCallback(() => {
    resultsRef.current?.exportCSV();
  }, []);

  // Memoize handlers to prevent re-creating on every render
  const shortcutHandlers = useMemo(
    () => ({
      'query.run': handleExecute,
      'query.save': handleSave,
      'query.cancel': handleCancel,
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
      'results.export': handleExportCSV,
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
      handleExportCSV,
      activeConnectionId,
      createTab,
      tabs,
      setActiveTab,
    ]
  );

  useKeyboardShortcuts(shortcutHandlers);

  const handleQuerySelect = useCallback(
    (query: SavedQuery) => {
      createTabWithContent(activeConnectionId, query.name, query.sql, true);
    },
    [activeConnectionId, createTabWithContent]
  );

  const handleLibraryMouseDown = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    setIsResizingLibrary(true);
  }, []);

  useEffect(() => {
    if (!isResizingLibrary) return;

    const handleMouseMove = (e: MouseEvent) => {
      const newWidth = e.clientX - 48; // Account for server rail width (48px)
      setLibraryWidth(Math.max(140, Math.min(300, newWidth)));
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
    <div className="h-full w-full flex flex-col bg-theme-bg-surface overflow-hidden" ref={containerRef}>
      {/* Top section: Saved Queries + Editor */}
      <div className="flex min-h-0 overflow-hidden" style={{ height: `${splitPosition}%` }}>
        {/* Query Library Sidebar */}
        {showQueryLibrary && (
          <div
            className="flex flex-col bg-theme-bg-surface border-r border-theme-border-primary relative flex-shrink-0"
            style={{ width: libraryWidth }}
          >
            <div className="flex items-center justify-between px-2 py-1 border-b border-theme-border-primary">
              <span className="text-[10px] font-medium text-theme-text-tertiary uppercase tracking-wider">
                Saved Queries
              </span>
              <button
                onClick={() => setShowQueryLibrary(false)}
                className="p-0.5 rounded hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary transition-colors"
                title="Hide query library"
              >
                <PanelLeftClose className="w-3.5 h-3.5" />
              </button>
            </div>
            <div className="flex-1 overflow-hidden">
              <SavedQueriesPanel onQuerySelect={handleQuerySelect} />
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
          {/* Toolbar */}
          <div className="flex items-center justify-between px-4 py-2 bg-theme-bg-elevated border-b border-theme-border-primary">
            <div className="flex items-center gap-2">
              {!showQueryLibrary && (
                <button
                  onClick={() => setShowQueryLibrary(true)}
                  className="p-2 rounded-lg hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary transition-colors"
                  title="Show query library"
                >
                  <PanelLeft className="w-4 h-4" />
                </button>
              )}
              <button
                onClick={handleExecute}
                disabled={!isConnected || activeTab?.isExecuting}
                className={cn(
                  'flex items-center gap-2 px-4 py-1.5 rounded-lg text-sm font-medium transition-all duration-200',
                  'bg-emerald-600 hover:bg-emerald-500 text-white',
                  'disabled:opacity-40 disabled:cursor-not-allowed disabled:hover:bg-emerald-600'
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
                    Run
                  </>
                )}
              </button>
              {activeTab?.isExecuting && (
                <button
                  onClick={handleCancel}
                  className="p-2 rounded-lg hover:bg-theme-bg-hover text-red-400 hover:text-red-300 transition-colors"
                  title="Cancel query"
                >
                  <Square className="w-4 h-4" />
                </button>
              )}
              <button
                onClick={handleClear}
                className="p-2 rounded-lg hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary transition-colors disabled:opacity-40"
                disabled={!activeTab?.results && !activeTab?.error}
                title="Clear results"
              >
                <Trash2 className="w-4 h-4" />
              </button>
              <div className="w-px h-5 bg-theme-border-secondary mx-1" />
              <button
                onClick={handleSave}
                className="p-2 rounded-lg hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary transition-colors disabled:opacity-40"
                disabled={!activeTab?.sql.trim()}
                title="Save query (Cmd+S)"
              >
                <Save className="w-4 h-4" />
              </button>
            </div>

            <div className="text-xs text-theme-text-tertiary flex items-center gap-4">
              {cursorPosition && (
                <span>
                  Ln {cursorPosition.line}, Col {cursorPosition.column}
                </span>
              )}
              {/* SQL Validation Status */}
              {isConnected && activeTab && (
                <div className="flex items-center gap-1.5">
                  {activeTab.validation.isValidating ? (
                    <span className="flex items-center gap-1 text-theme-text-muted">
                      <Loader2 className="w-3.5 h-3.5 animate-spin" />
                      Checking...
                    </span>
                  ) : activeTab.validation.isValid ? (
                    activeTab.sql.trim() ? (
                      <span className="flex items-center gap-1 text-emerald-500">
                        <CheckCircle2 className="w-3.5 h-3.5" />
                        Valid
                      </span>
                    ) : null
                  ) : (
                    <span
                      className="flex items-center gap-1 text-red-400 cursor-help max-w-md"
                      title={activeTab.validation.error?.message || 'SQL error'}
                    >
                      <XCircle className="w-3.5 h-3.5 flex-shrink-0" />
                      <span className="truncate">
                        {activeTab.validation.error?.message || 'SQL error'}
                      </span>
                    </span>
                  )}
                </div>
              )}
              {isConnected ? (
                <span className="text-emerald-500 font-medium">Connected</span>
              ) : (
                <span>Connect to run queries</span>
              )}
            </div>
          </div>

          {/* Tabs */}
          <QueryTabs />

          {/* Editor pane */}
          <div className="flex-1 bg-theme-bg-surface overflow-hidden">
            {activeTabId ? (
              <QueryEditor tabId={activeTabId} />
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

      {/* Resize handle - full width */}
      <div
        onMouseDown={handleMouseDown}
        className={cn(
          'h-1 cursor-row-resize flex-shrink-0 transition-colors',
          isResizing ? 'bg-theme-bg-active' : 'hover:bg-theme-bg-hover'
        )}
      />

      {/* Results pane - full width */}
      <div
        className="bg-theme-bg-elevated overflow-hidden min-w-0"
        style={{ height: `${100 - splitPosition}%` }}
      >
        <ResultsGrid
          ref={resultsRef}
          results={activeTab?.results ?? null}
          error={activeTab?.error ?? null}
          executionTime={activeTab?.executionTime ?? null}
          isExecuting={activeTab?.isExecuting ?? false}
        />
      </div>

      {/* Save Query Dialog */}
      <SaveQueryDialog
        isOpen={showSaveDialog}
        onClose={() => setShowSaveDialog(false)}
        sql={activeTab?.sql || ''}
        initialName={activeTab?.name || ''}
      />
    </div>
  );
}
