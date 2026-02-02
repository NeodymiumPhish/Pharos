// Connection types
export interface ConnectionConfig {
  id: string;
  name: string;
  host: string;
  port: number;
  database: string;
  username: string;
  password: string;
}

export type ConnectionStatus = 'disconnected' | 'connecting' | 'connected' | 'error';

export interface Connection {
  config: ConnectionConfig;
  status: ConnectionStatus;
  error?: string;
  latency?: number;
}

// Schema types
export interface DatabaseInfo {
  name: string;
  schemas: SchemaInfo[];
}

export interface SchemaInfo {
  name: string;
  tables: TableInfo[];
}

export interface TableInfo {
  name: string;
  tableType: 'table' | 'view';
  columns: ColumnInfo[];
}

export interface ColumnInfo {
  name: string;
  dataType: string;
  isNullable: boolean;
  isPrimaryKey: boolean;
  ordinalPosition: number;
}

// Tree node types for the navigator
export type TreeNodeType = 'connection' | 'database' | 'schema' | 'tables' | 'views' | 'table' | 'view' | 'column';

export interface TreeNode {
  id: string;
  label: string;
  type: TreeNodeType;
  children?: TreeNode[];
  isExpanded?: boolean;
  isLoading?: boolean;
  metadata?: {
    dataType?: string;
    isPrimaryKey?: boolean;
    connectionId?: string;
    schemaName?: string;
    tableName?: string;
  };
}

// Query types (for future phases)
export interface QueryResult {
  columns: string[];
  rows: Record<string, unknown>[];
  rowCount: number;
  executionTime: number;
  hasMore: boolean;
  cursorId?: string;
}

export interface SavedQuery {
  id: string;
  name: string;
  folder?: string;
  sql: string;
  connectionId?: string;
  createdAt: string;
  updatedAt: string;
}

export interface CreateSavedQuery {
  name: string;
  folder?: string;
  sql: string;
  connectionId?: string;
}

export interface UpdateSavedQuery {
  id: string;
  name?: string;
  folder?: string;
  sql?: string;
}

// Settings types
export type ThemeMode = 'light' | 'dark' | 'auto';

export interface EditorSettings {
  fontSize: number;
  fontFamily: string;
  tabSize: number;
  wordWrap: boolean;
  minimap: boolean;
  lineNumbers: boolean;
}

export interface QuerySettings {
  defaultLimit: number;
  timeoutSeconds: number;
  autoCommit: boolean;
  confirmDestructive: boolean;
}

export interface UISettings {
  navigatorWidth: number;
  savedQueriesWidth: number;
  resultsPanelHeight: number;
}

// Keyboard shortcuts types
export type ShortcutModifier = 'cmd' | 'shift' | 'alt';

export interface KeyboardShortcut {
  id: string;
  label: string;
  description: string;
  key: string;
  modifiers: ShortcutModifier[];
}

export interface KeyboardSettings {
  shortcuts: Record<string, KeyboardShortcut>;
}

export const DEFAULT_SHORTCUTS: Record<string, KeyboardShortcut> = {
  'query.run': { id: 'query.run', label: 'Run Query', description: 'Execute the current query', key: 'Enter', modifiers: ['cmd'] },
  'query.save': { id: 'query.save', label: 'Save Query', description: 'Save current query to library', key: 's', modifiers: ['cmd'] },
  'query.cancel': { id: 'query.cancel', label: 'Cancel Query', description: 'Cancel running query', key: 'Escape', modifiers: [] },
  'tab.new': { id: 'tab.new', label: 'New Tab', description: 'Create a new query tab', key: 't', modifiers: ['cmd'] },
  'tab.close': { id: 'tab.close', label: 'Close Tab', description: 'Close the current tab', key: 'w', modifiers: ['cmd'] },
  'tab.reopen': { id: 'tab.reopen', label: 'Reopen Tab', description: 'Reopen last closed tab', key: 't', modifiers: ['cmd', 'shift'] },
  'tab.next': { id: 'tab.next', label: 'Next Tab', description: 'Switch to next tab', key: ']', modifiers: ['cmd'] },
  'tab.prev': { id: 'tab.prev', label: 'Previous Tab', description: 'Switch to previous tab', key: '[', modifiers: ['cmd'] },
  'tab.1': { id: 'tab.1', label: 'Tab 1', description: 'Switch to tab 1', key: '1', modifiers: ['cmd'] },
  'tab.2': { id: 'tab.2', label: 'Tab 2', description: 'Switch to tab 2', key: '2', modifiers: ['cmd'] },
  'tab.3': { id: 'tab.3', label: 'Tab 3', description: 'Switch to tab 3', key: '3', modifiers: ['cmd'] },
  'tab.4': { id: 'tab.4', label: 'Tab 4', description: 'Switch to tab 4', key: '4', modifiers: ['cmd'] },
  'tab.5': { id: 'tab.5', label: 'Tab 5', description: 'Switch to tab 5', key: '5', modifiers: ['cmd'] },
  'tab.6': { id: 'tab.6', label: 'Tab 6', description: 'Switch to tab 6', key: '6', modifiers: ['cmd'] },
  'tab.7': { id: 'tab.7', label: 'Tab 7', description: 'Switch to tab 7', key: '7', modifiers: ['cmd'] },
  'tab.8': { id: 'tab.8', label: 'Tab 8', description: 'Switch to tab 8', key: '8', modifiers: ['cmd'] },
  'tab.9': { id: 'tab.9', label: 'Last Tab', description: 'Switch to last tab', key: '9', modifiers: ['cmd'] },
  'results.copy': { id: 'results.copy', label: 'Copy Results', description: 'Copy results to clipboard', key: 'c', modifiers: ['cmd', 'shift'] },
  'results.export': { id: 'results.export', label: 'Export CSV', description: 'Export results as CSV', key: 'e', modifiers: ['cmd'] },
};

export interface AppSettings {
  theme: ThemeMode;
  editor: EditorSettings;
  query: QuerySettings;
  ui: UISettings;
  keyboard: KeyboardSettings;
}

export const DEFAULT_SETTINGS: AppSettings = {
  theme: 'auto',
  editor: {
    fontSize: 13,
    fontFamily: 'JetBrains Mono, Monaco, Menlo, monospace',
    tabSize: 2,
    wordWrap: false,
    minimap: false,
    lineNumbers: true,
  },
  query: {
    defaultLimit: 1000,
    timeoutSeconds: 30,
    autoCommit: true,
    confirmDestructive: true,
  },
  ui: {
    navigatorWidth: 260,
    savedQueriesWidth: 240,
    resultsPanelHeight: 300,
  },
  keyboard: {
    shortcuts: DEFAULT_SHORTCUTS,
  },
};
