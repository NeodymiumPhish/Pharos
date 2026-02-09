import type { languages, Position, editor } from 'monaco-editor';
import type { SchemaInfo, TableInfo, ColumnInfo } from '@/lib/types';

// SQL keywords for autocomplete
const SQL_KEYWORDS = [
  'SELECT', 'FROM', 'WHERE', 'AND', 'OR', 'NOT', 'IN', 'LIKE', 'ILIKE',
  'BETWEEN', 'IS', 'NULL', 'TRUE', 'FALSE',
  'ORDER', 'BY', 'ASC', 'DESC', 'NULLS', 'FIRST', 'LAST',
  'GROUP', 'HAVING', 'LIMIT', 'OFFSET',
  'JOIN', 'INNER', 'LEFT', 'RIGHT', 'FULL', 'OUTER', 'CROSS', 'ON',
  'UNION', 'ALL', 'INTERSECT', 'EXCEPT',
  'INSERT', 'INTO', 'VALUES', 'DEFAULT',
  'UPDATE', 'SET',
  'DELETE',
  'CREATE', 'TABLE', 'INDEX', 'VIEW', 'SCHEMA', 'DATABASE',
  'ALTER', 'ADD', 'DROP', 'COLUMN', 'CONSTRAINT',
  'PRIMARY', 'KEY', 'FOREIGN', 'REFERENCES', 'UNIQUE', 'CHECK',
  'CASCADE', 'RESTRICT',
  'AS', 'DISTINCT', 'CASE', 'WHEN', 'THEN', 'ELSE', 'END',
  'COALESCE', 'NULLIF', 'CAST',
  'COUNT', 'SUM', 'AVG', 'MIN', 'MAX',
  'EXISTS', 'ANY', 'SOME',
  'WITH', 'RECURSIVE',
  'RETURNING',
];

// SQL functions for autocomplete
const SQL_FUNCTIONS = [
  // Aggregate functions
  'count', 'sum', 'avg', 'min', 'max', 'array_agg', 'string_agg', 'bool_and', 'bool_or',
  // String functions
  'length', 'lower', 'upper', 'trim', 'ltrim', 'rtrim', 'substring', 'concat', 'replace',
  'split_part', 'regexp_replace', 'regexp_matches', 'position', 'strpos', 'left', 'right',
  // Date/time functions
  'now', 'current_date', 'current_time', 'current_timestamp', 'date_trunc', 'extract',
  'age', 'date_part', 'to_char', 'to_date', 'to_timestamp',
  // Numeric functions
  'abs', 'ceil', 'floor', 'round', 'trunc', 'mod', 'power', 'sqrt', 'random',
  // JSON functions
  'json_build_object', 'json_agg', 'jsonb_build_object', 'jsonb_agg',
  'json_extract_path', 'jsonb_extract_path', 'json_array_elements', 'jsonb_array_elements',
  // Array functions
  'array_length', 'unnest', 'array_append', 'array_prepend', 'array_cat',
  // Other
  'coalesce', 'nullif', 'greatest', 'least', 'generate_series',
];

// SQL snippets for common query patterns
const SQL_SNIPPETS: { prefix: string; label: string; body: string; detail: string }[] = [
  {
    prefix: 'sel',
    label: 'sel - SELECT query',
    body: 'SELECT ${1:*}\nFROM ${2:table_name}\nWHERE ${3:condition}\nLIMIT ${4:100};',
    detail: 'SELECT ... FROM ... WHERE',
  },
  {
    prefix: 'selc',
    label: 'selc - SELECT COUNT',
    body: 'SELECT COUNT(*) FROM ${1:table_name}\nWHERE ${2:1=1};',
    detail: 'SELECT COUNT(*) FROM',
  },
  {
    prefix: 'selg',
    label: 'selg - SELECT with GROUP BY',
    body: 'SELECT ${1:column}, COUNT(*) AS cnt\nFROM ${2:table_name}\nGROUP BY ${1:column}\nORDER BY cnt DESC\nLIMIT ${3:100};',
    detail: 'SELECT ... GROUP BY ... ORDER BY',
  },
  {
    prefix: 'cte',
    label: 'cte - Common Table Expression',
    body: 'WITH ${1:cte_name} AS (\n  SELECT ${2:*}\n  FROM ${3:table_name}\n  WHERE ${4:condition}\n)\nSELECT *\nFROM ${1:cte_name};',
    detail: 'WITH ... AS (...) SELECT',
  },
  {
    prefix: 'ins',
    label: 'ins - INSERT INTO',
    body: 'INSERT INTO ${1:table_name} (${2:columns})\nVALUES (${3:values})\nRETURNING *;',
    detail: 'INSERT INTO ... VALUES',
  },
  {
    prefix: 'upd',
    label: 'upd - UPDATE',
    body: 'UPDATE ${1:table_name}\nSET ${2:column} = ${3:value}\nWHERE ${4:condition}\nRETURNING *;',
    detail: 'UPDATE ... SET ... WHERE',
  },
  {
    prefix: 'del',
    label: 'del - DELETE',
    body: 'DELETE FROM ${1:table_name}\nWHERE ${2:condition}\nRETURNING *;',
    detail: 'DELETE FROM ... WHERE',
  },
  {
    prefix: 'join',
    label: 'join - JOIN template',
    body: 'SELECT ${1:*}\nFROM ${2:table1} t1\nJOIN ${3:table2} t2 ON t1.${4:id} = t2.${5:foreign_id}\nWHERE ${6:1=1}\nLIMIT ${7:100};',
    detail: 'SELECT ... JOIN ... ON',
  },
  {
    prefix: 'ljoin',
    label: 'ljoin - LEFT JOIN template',
    body: 'SELECT ${1:*}\nFROM ${2:table1} t1\nLEFT JOIN ${3:table2} t2 ON t1.${4:id} = t2.${5:foreign_id}\nWHERE ${6:1=1}\nLIMIT ${7:100};',
    detail: 'SELECT ... LEFT JOIN ... ON',
  },
  {
    prefix: 'wf',
    label: 'wf - Window Function',
    body: '${1:ROW_NUMBER}() OVER (\n  PARTITION BY ${2:partition_column}\n  ORDER BY ${3:order_column}\n) AS ${4:row_num}',
    detail: 'Window function with OVER',
  },
  {
    prefix: 'expl',
    label: 'expl - EXPLAIN ANALYZE',
    body: 'EXPLAIN (ANALYZE, COSTS, BUFFERS, FORMAT TEXT)\n${1:SELECT * FROM table_name};',
    detail: 'EXPLAIN ANALYZE wrapper',
  },
  {
    prefix: 'crtb',
    label: 'crtb - CREATE TABLE',
    body: 'CREATE TABLE ${1:table_name} (\n  id SERIAL PRIMARY KEY,\n  ${2:column_name} ${3:TEXT} NOT NULL,\n  created_at TIMESTAMPTZ DEFAULT now()\n);',
    detail: 'CREATE TABLE with columns',
  },
  {
    prefix: 'idx',
    label: 'idx - CREATE INDEX',
    body: 'CREATE INDEX ${1:idx_name} ON ${2:table_name} (${3:column_name});',
    detail: 'CREATE INDEX ON table',
  },
  {
    prefix: 'case',
    label: 'case - CASE expression',
    body: 'CASE\n  WHEN ${1:condition} THEN ${2:result}\n  ELSE ${3:default}\nEND',
    detail: 'CASE WHEN ... THEN ... ELSE ... END',
  },
];

export interface SchemaMetadata {
  schemas: SchemaInfo[];
  tables: Map<string, TableInfo[]>; // schemaName -> tables
  columns: Map<string, ColumnInfo[]>; // schemaName.tableName -> columns
}

export function createCompletionProvider(
  getMetadata: () => SchemaMetadata | null
): languages.CompletionItemProvider {
  return {
    triggerCharacters: ['.', ' '],

    provideCompletionItems(
      model: editor.ITextModel,
      position: Position
    ): languages.ProviderResult<languages.CompletionList> {
      const metadata = getMetadata();
      const word = model.getWordUntilPosition(position);
      const range = {
        startLineNumber: position.lineNumber,
        endLineNumber: position.lineNumber,
        startColumn: word.startColumn,
        endColumn: word.endColumn,
      };

      // Get the text before the cursor to determine context
      const textBeforeCursor = model.getValueInRange({
        startLineNumber: 1,
        startColumn: 1,
        endLineNumber: position.lineNumber,
        endColumn: position.column,
      });

      const suggestions: languages.CompletionItem[] = [];

      // Check if we just typed a dot (table.column completion)
      const lastDotMatch = textBeforeCursor.match(/(\w+)\.\s*$/);
      if (lastDotMatch && metadata) {
        const prefix = lastDotMatch[1].toLowerCase();

        // Check if it's a schema name
        const schema = metadata.schemas.find(
          (s) => s.name.toLowerCase() === prefix
        );
        if (schema) {
          const tables = metadata.tables.get(schema.name) || [];
          tables.forEach((table) => {
            suggestions.push({
              label: table.name,
              kind: 1, // Class (table icon)
              insertText: table.name,
              detail: table.tableType === 'view' ? 'View' : 'Table',
              range,
            });
          });
        }

        // Check if it's a table name (add column completions)
        metadata.columns.forEach((columns, key) => {
          const [, tableName] = key.split('.');
          if (tableName?.toLowerCase() === prefix) {
            columns.forEach((col) => {
              suggestions.push({
                label: col.name,
                kind: 4, // Field (column icon)
                insertText: col.name,
                detail: col.dataType,
                documentation: col.isPrimaryKey ? 'Primary Key' : undefined,
                range,
              });
            });
          }
        });

        if (suggestions.length > 0) {
          return { suggestions };
        }
      }

      // Add SQL keywords
      SQL_KEYWORDS.forEach((keyword) => {
        suggestions.push({
          label: keyword,
          kind: 13, // Keyword
          insertText: keyword,
          range,
        });
      });

      // Add SQL functions
      SQL_FUNCTIONS.forEach((func) => {
        suggestions.push({
          label: func,
          kind: 2, // Function
          insertText: `${func}($0)`,
          insertTextRules: 4, // InsertAsSnippet
          range,
        });
      });

      // Add SQL snippets
      SQL_SNIPPETS.forEach((snippet) => {
        suggestions.push({
          label: snippet.label,
          kind: 27, // Snippet
          insertText: snippet.body,
          insertTextRules: 4, // InsertAsSnippet
          detail: snippet.detail,
          documentation: snippet.detail,
          sortText: `0-${snippet.prefix}`, // Sort snippets near the top
          range,
        });
      });

      // Add schema names
      if (metadata) {
        metadata.schemas.forEach((schema) => {
          suggestions.push({
            label: schema.name,
            kind: 8, // Module (schema icon)
            insertText: schema.name,
            detail: 'Schema',
            range,
          });
        });

        // Add table names
        metadata.tables.forEach((tables) => {
          tables.forEach((table) => {
            suggestions.push({
              label: table.name,
              kind: 1, // Class (table icon)
              insertText: table.name,
              detail: table.tableType === 'view' ? 'View' : 'Table',
              range,
            });
          });
        });
      }

      return { suggestions };
    },
  };
}
