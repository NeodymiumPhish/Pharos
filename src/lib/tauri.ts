import { invoke } from '@tauri-apps/api/core';
import type {
  ConnectionConfig,
  SchemaInfo,
  TableInfo,
  ColumnInfo,
  AnalyzeResult,
  IndexInfo,
  ConstraintInfo,
  FunctionInfo,
  AppSettings,
  CloneTableOptions,
  CloneTableResult,
  CsvValidationResult,
  ImportCsvOptions,
  ImportCsvResult,
  ExportTableOptions,
  ExportTableResult,
  ExportResultsOptions,
  ExportQueryOptions,
  QueryHistoryEntry,
  QueryHistoryResultData,
  EditableInfo,
  RowEdit,
  CommitEditsResult,
} from './types';

// Connection commands
export async function saveConnection(config: ConnectionConfig): Promise<void> {
  return invoke('save_connection', { config });
}

export async function deleteConnection(connectionId: string): Promise<void> {
  return invoke('delete_connection', { connectionId });
}

export async function loadConnections(): Promise<ConnectionConfig[]> {
  return invoke('load_connections');
}

export interface ConnectionInfo {
  id: string;
  name: string;
  host: string;
  port: number;
  database: string;
  status: 'connected' | 'disconnected' | 'connecting' | 'error';
  error?: string;
  latency_ms?: number;
}

export async function connectPostgres(connectionId: string): Promise<ConnectionInfo> {
  return invoke('connect_postgres', { connectionId });
}

export async function disconnectPostgres(connectionId: string): Promise<void> {
  return invoke('disconnect_postgres', { connectionId });
}

export async function testConnection(config: ConnectionConfig): Promise<{ success: boolean; latency_ms?: number; error?: string }> {
  return invoke('test_connection', { config });
}

export async function reorderConnections(connectionIds: string[]): Promise<void> {
  return invoke('reorder_connections', { connectionIds });
}

// Schema introspection commands
export async function getSchemas(connectionId: string): Promise<SchemaInfo[]> {
  return invoke('get_schemas', { connectionId });
}

export async function getTables(connectionId: string, schemaName: string): Promise<TableInfo[]> {
  return invoke('get_tables', { connectionId, schemaName });
}

export async function getColumns(connectionId: string, schemaName: string, tableName: string): Promise<ColumnInfo[]> {
  return invoke('get_columns', { connectionId, schemaName, tableName });
}

export async function analyzeSchema(connectionId: string, schemaName: string): Promise<AnalyzeResult> {
  return invoke('analyze_schema', { connectionId, schemaName });
}

export async function getTableIndexes(connectionId: string, schemaName: string, tableName: string): Promise<IndexInfo[]> {
  return invoke('get_table_indexes', { connectionId, schemaName, tableName });
}

export async function getTableConstraints(connectionId: string, schemaName: string, tableName: string): Promise<ConstraintInfo[]> {
  return invoke('get_table_constraints', { connectionId, schemaName, tableName });
}

export async function getSchemaFunctions(connectionId: string, schemaName: string): Promise<FunctionInfo[]> {
  return invoke('get_schema_functions', { connectionId, schemaName });
}

export async function generateTableDdl(connectionId: string, schemaName: string, tableName: string): Promise<string> {
  return invoke('generate_table_ddl', { connectionId, schemaName, tableName });
}

export async function generateIndexDdl(connectionId: string, schemaName: string, indexName: string): Promise<string> {
  return invoke('generate_index_ddl', { connectionId, schemaName, indexName });
}

// Query execution commands
export interface QueryResult {
  columns: { name: string; data_type: string }[];
  rows: Record<string, unknown>[];
  row_count: number;
  execution_time_ms: number;
  has_more: boolean;
  history_entry_id?: string;
}

export interface ExecuteResult {
  rows_affected: number;
  execution_time_ms: number;
}

export async function executeQuery(
  connectionId: string,
  sql: string,
  queryId?: string,
  limit?: number,
  schema?: string | null
): Promise<QueryResult> {
  return invoke('execute_query', { connectionId, sql, queryId, limit, schema });
}

export async function fetchMoreRows(
  connectionId: string,
  sql: string,
  limit: number,
  offset: number,
  schema?: string | null
): Promise<QueryResult> {
  return invoke('fetch_more_rows', { connectionId, sql, limit, offset, schema: schema ?? null });
}

export async function cancelQuery(
  connectionId: string,
  queryId: string
): Promise<boolean> {
  return invoke('cancel_query', { connectionId, queryId });
}

export async function executeStatement(
  connectionId: string,
  sql: string
): Promise<ExecuteResult> {
  return invoke('execute_statement', { connectionId, sql });
}

// SQL validation
export interface ValidationError {
  message: string;
  position?: number;
  line?: number;
  column?: number;
}

export interface ValidationResult {
  valid: boolean;
  error?: ValidationError;
}

export async function validateSql(
  connectionId: string,
  sql: string,
  schema?: string | null
): Promise<ValidationResult> {
  return invoke('validate_sql', { connectionId, sql, schema });
}

// Utility function to build connection string (for display purposes)
export function buildConnectionString(config: ConnectionConfig): string {
  return `postgresql://${config.username}@${config.host}:${config.port}/${config.database}`;
}

// Settings commands
export async function loadSettings(): Promise<AppSettings> {
  return invoke('load_settings');
}

export async function saveSettings(settings: AppSettings): Promise<void> {
  // Ensure UI settings are integers (Rust expects u32)
  const sanitizedSettings = {
    ...settings,
    ui: {
      ...settings.ui,
      navigatorWidth: Math.round(settings.ui.navigatorWidth),
      savedQueriesWidth: Math.round(settings.ui.savedQueriesWidth),
      resultsPanelHeight: Math.round(settings.ui.resultsPanelHeight),
      editorSplitPosition: Math.round(settings.ui.editorSplitPosition),
    },
    editor: {
      ...settings.editor,
      fontSize: Math.round(settings.editor.fontSize),
      tabSize: Math.round(settings.editor.tabSize),
    },
    query: {
      ...settings.query,
      defaultLimit: Math.round(settings.query.defaultLimit),
      timeoutSeconds: Math.round(settings.query.timeoutSeconds),
    },
  };
  return invoke('save_settings', { settings: sanitizedSettings });
}

// Table operation commands
export async function cloneTable(
  connectionId: string,
  options: CloneTableOptions
): Promise<CloneTableResult> {
  return invoke('clone_table', { connectionId, options });
}

export async function validateCsvForImport(
  connectionId: string,
  schemaName: string,
  tableName: string,
  filePath: string,
  hasHeaders: boolean
): Promise<CsvValidationResult> {
  return invoke('validate_csv_for_import', {
    connectionId,
    schemaName,
    tableName,
    filePath,
    hasHeaders,
  });
}

export async function importCsv(
  connectionId: string,
  options: ImportCsvOptions
): Promise<ImportCsvResult> {
  return invoke('import_csv', { connectionId, options });
}

export async function exportTable(
  connectionId: string,
  options: ExportTableOptions
): Promise<ExportTableResult> {
  return invoke('export_table', { connectionId, options });
}

export async function exportResults(
  options: ExportResultsOptions
): Promise<ExportTableResult> {
  return invoke('export_results', { options });
}

export async function writeTextExport(filePath: string, content: string): Promise<void> {
  return invoke('write_text_export', { filePath, content });
}

export async function exportQuery(
  connectionId: string,
  options: ExportQueryOptions
): Promise<ExportTableResult> {
  return invoke('export_query', { connectionId, options });
}

// Query history commands
export async function loadQueryHistory(
  connectionId?: string,
  search?: string,
  limit?: number,
  offset?: number
): Promise<QueryHistoryEntry[]> {
  return invoke('load_query_history', {
    connectionId: connectionId ?? null,
    search: search ?? null,
    limit: limit ?? null,
    offset: offset ?? null,
  });
}

export async function deleteQueryHistoryEntry(entryId: string): Promise<boolean> {
  return invoke('delete_query_history_entry', { entryId });
}

export async function clearQueryHistory(): Promise<void> {
  return invoke('clear_query_history');
}

export async function getQueryHistoryResult(entryId: string): Promise<QueryHistoryResultData | null> {
  return invoke('get_query_history_result', { entryId });
}

export async function updateQueryHistoryResults(
  entryId: string,
  rowCount: number,
  resultColumns: string,
  resultRows: string
): Promise<boolean> {
  return invoke('update_query_history_results', { entryId, rowCount, resultColumns, resultRows });
}

// Inline editing commands
export async function checkQueryEditable(connectionId: string, sql: string, schema?: string): Promise<EditableInfo> {
  return invoke('check_query_editable', { connectionId, sql, schema: schema ?? null });
}

export async function commitDataEdits(connectionId: string, options: { schemaName: string; tableName: string; primaryKeys: string[]; edits: RowEdit[] }): Promise<CommitEditsResult> {
  return invoke('commit_data_edits', { connectionId, options });
}
