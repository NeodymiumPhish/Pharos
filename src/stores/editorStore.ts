import { create } from 'zustand';

export interface ValidationError {
  message: string;
  position?: number;
  line?: number;
  column?: number;
}

export interface ValidationState {
  isValid: boolean;
  isValidating: boolean;
  error: ValidationError | null;
}

export interface QueryTab {
  id: string;
  name: string;
  connectionId: string | null;
  sql: string;
  cursorPosition: { line: number; column: number };
  isDirty: boolean;
  isExecuting: boolean;
  queryId: string | null; // ID of currently running query (for cancellation)
  results: QueryResults | null;
  error: string | null;
  executionTime: number | null;
  validation: ValidationState;
  savedQueryName: string | null; // Name from saved query, preserved through execution
  savedQueryId: string | null; // ID of the saved query this tab was opened from
  editableInfo?: import('@/lib/types').EditableInfo | null;
  pendingEdits?: import('@/lib/types').RowEdit[];
}

export interface QueryResults {
  columns: ColumnDef[];
  rows: Record<string, unknown>[];
  rowCount: number;
  hasMore: boolean;
  cursorId?: string;
  explainPlan?: import('@/lib/types').ExplainPlanNode[];
  explainRawJson?: string;
}

export interface ColumnDef {
  name: string;
  dataType: string;
}

interface EditorState {
  tabs: QueryTab[];
  activeTabId: string | null;
  pinnedResultsTabId: string | null;

  // Actions
  createTab: (connectionId: string | null) => string;
  createTabWithContent: (connectionId: string | null, name: string, sql: string, savedQueryId?: string | null) => string;
  closeTab: (tabId: string) => void;
  setActiveTab: (tabId: string) => void;
  updateTabSql: (tabId: string, sql: string) => void;
  updateTabName: (tabId: string, name: string) => void;
  updateCursorPosition: (tabId: string, line: number, column: number) => void;
  setTabExecuting: (tabId: string, isExecuting: boolean, queryId?: string | null) => void;
  setTabResults: (tabId: string, results: QueryResults | null, executionTime: number | null) => void;
  setTabError: (tabId: string, error: string | null) => void;
  clearTabResults: (tabId: string) => void;
  setTabValidation: (tabId: string, validation: ValidationState) => void;
  setTabValidating: (tabId: string, isValidating: boolean) => void;
  pinResults: (tabId: string) => void;
  unpinResults: () => void;
  setTabEditableInfo: (tabId: string, info: import('@/lib/types').EditableInfo | null) => void;
  addPendingEdit: (tabId: string, edit: import('@/lib/types').RowEdit) => void;
  clearPendingEdits: (tabId: string) => void;

  // Getters
  getActiveTab: () => QueryTab | undefined;
  getTab: (tabId: string) => QueryTab | undefined;
}

let tabCounter = 1;

// Extract table name from SQL query (simple heuristic)
function extractTableName(sql: string): string | null {
  // Normalize whitespace and remove comments
  const normalized = sql
    .replace(/--.*$/gm, '') // Remove single-line comments
    .replace(/\/\*[\s\S]*?\*\//g, '') // Remove multi-line comments
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase();

  // Match SELECT ... FROM table_name patterns
  const fromMatch = normalized.match(/\bfrom\s+(["`]?[\w.]+["`]?)/i);
  if (fromMatch) {
    // Remove quotes and schema prefix, get just the table name
    let tableName = fromMatch[1].replace(/["`]/g, '');
    // If there's a schema prefix (schema.table), take just the table
    if (tableName.includes('.')) {
      tableName = tableName.split('.').pop() || tableName;
    }
    return tableName;
  }

  return null;
}

export const useEditorStore = create<EditorState>((set, get) => ({
  tabs: [],
  activeTabId: null,
  pinnedResultsTabId: null,

  createTab: (connectionId) => {
    const id = `tab-${Date.now()}-${tabCounter++}`;
    const newTab: QueryTab = {
      id,
      name: 'New Query',
      connectionId,
      sql: '',
      cursorPosition: { line: 1, column: 1 },
      isDirty: false,
      isExecuting: false,
      queryId: null,
      results: null,
      error: null,
      executionTime: null,
      validation: { isValid: true, isValidating: false, error: null },
      savedQueryName: null,
      savedQueryId: null,
    };

    set((state) => ({
      tabs: [...state.tabs, newTab],
      activeTabId: id,
    }));

    return id;
  },

  createTabWithContent: (connectionId, name, sql, savedQueryId = null) => {
    const id = `tab-${Date.now()}-${tabCounter++}`;
    const newTab: QueryTab = {
      id,
      name,
      connectionId,
      sql,
      cursorPosition: { line: 1, column: 1 },
      isDirty: false,
      isExecuting: false,
      queryId: null,
      results: null,
      error: null,
      executionTime: null,
      validation: { isValid: true, isValidating: false, error: null },
      savedQueryName: savedQueryId ? name : null,
      savedQueryId,
    };

    set((state) => ({
      tabs: [...state.tabs, newTab],
      activeTabId: id,
    }));

    return id;
  },

  closeTab: (tabId) => {
    set((state) => {
      const tabIndex = state.tabs.findIndex((t) => t.id === tabId);
      const newTabs = state.tabs.filter((t) => t.id !== tabId);

      let newActiveTabId = state.activeTabId;
      if (state.activeTabId === tabId) {
        if (newTabs.length > 0) {
          // Select the tab to the left, or the first tab if closing the first
          const newIndex = Math.max(0, tabIndex - 1);
          newActiveTabId = newTabs[newIndex]?.id ?? null;
        } else {
          newActiveTabId = null;
        }
      }

      // Auto-unpin if the closed tab was pinned
      const newPinnedResultsTabId = state.pinnedResultsTabId === tabId ? null : state.pinnedResultsTabId;

      return { tabs: newTabs, activeTabId: newActiveTabId, pinnedResultsTabId: newPinnedResultsTabId };
    });
  },

  setActiveTab: (tabId) => {
    set({ activeTabId: tabId });
  },

  updateTabSql: (tabId, sql) => {
    set((state) => ({
      tabs: state.tabs.map((t) =>
        t.id === tabId ? { ...t, sql, isDirty: true } : t
      ),
    }));
  },

  updateTabName: (tabId, name) => {
    set((state) => ({
      tabs: state.tabs.map((t) =>
        t.id === tabId ? { ...t, name } : t
      ),
    }));
  },

  updateCursorPosition: (tabId, line, column) => {
    set((state) => ({
      tabs: state.tabs.map((t) =>
        t.id === tabId ? { ...t, cursorPosition: { line, column } } : t
      ),
    }));
  },

  setTabExecuting: (tabId, isExecuting, queryId = null) => {
    set((state) => ({
      tabs: state.tabs.map((t) =>
        t.id === tabId
          ? { ...t, isExecuting, queryId: isExecuting ? queryId : null, error: isExecuting ? null : t.error }
          : t
      ),
    }));
  },

  setTabResults: (tabId, results, executionTime) => {
    set((state) => ({
      tabs: state.tabs.map((t) => {
        if (t.id !== tabId) return t;

        // Determine the new name
        let newName = t.name;
        // Only auto-rename if it's still "New Query" and not from a saved query
        if (t.name === 'New Query' && !t.savedQueryName && results) {
          const tableName = extractTableName(t.sql);
          if (tableName) {
            newName = tableName;
          }
        }

        return {
          ...t,
          name: newName,
          results,
          executionTime,
          isExecuting: false,
          error: null,
        };
      }),
    }));
  },

  setTabError: (tabId, error) => {
    set((state) => ({
      tabs: state.tabs.map((t) =>
        t.id === tabId
          ? { ...t, error, isExecuting: false, results: null }
          : t
      ),
    }));
  },

  clearTabResults: (tabId) => {
    set((state) => ({
      tabs: state.tabs.map((t) =>
        t.id === tabId
          ? { ...t, results: null, error: null, executionTime: null }
          : t
      ),
    }));
  },

  setTabValidation: (tabId, validation) => {
    set((state) => ({
      tabs: state.tabs.map((t) =>
        t.id === tabId ? { ...t, validation } : t
      ),
    }));
  },

  setTabValidating: (tabId, isValidating) => {
    set((state) => ({
      tabs: state.tabs.map((t) =>
        t.id === tabId
          ? { ...t, validation: { ...t.validation, isValidating } }
          : t
      ),
    }));
  },

  pinResults: (tabId) => {
    set({ pinnedResultsTabId: tabId });
  },

  unpinResults: () => {
    set({ pinnedResultsTabId: null });
  },

  setTabEditableInfo: (tabId, info) => {
    set((state) => ({
      tabs: state.tabs.map((t) =>
        t.id === tabId ? { ...t, editableInfo: info } : t
      ),
    }));
  },

  addPendingEdit: (tabId, edit) => {
    set((state) => ({
      tabs: state.tabs.map((t) => {
        if (t.id !== tabId) return t;
        const existing = t.pendingEdits ?? [];
        // For updates, merge with existing edit for same row
        if (edit.type === 'update') {
          const existingIdx = existing.findIndex((e) => e.type === 'update' && e.rowIndex === edit.rowIndex);
          if (existingIdx >= 0) {
            const merged = {
              ...existing[existingIdx],
              changes: { ...existing[existingIdx].changes, ...edit.changes },
            };
            const updated = [...existing];
            updated[existingIdx] = merged;
            return { ...t, pendingEdits: updated };
          }
        }
        return { ...t, pendingEdits: [...existing, edit] };
      }),
    }));
  },

  clearPendingEdits: (tabId) => {
    set((state) => ({
      tabs: state.tabs.map((t) =>
        t.id === tabId ? { ...t, pendingEdits: [] } : t
      ),
    }));
  },

  getActiveTab: () => {
    const { tabs, activeTabId } = get();
    return tabs.find((t) => t.id === activeTabId);
  },

  getTab: (tabId) => {
    return get().tabs.find((t) => t.id === tabId);
  },
}));
