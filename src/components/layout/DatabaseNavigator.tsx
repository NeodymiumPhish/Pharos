import { useState, useRef, useCallback, useEffect, useMemo } from 'react';
import { Search, ChevronDown, RefreshCw, Database, Copy, Upload, Download, Table, Eye, ClipboardCopy, Code, Loader2 } from 'lucide-react';
import { cn } from '@/lib/cn';
import { SchemaTree } from '@/components/tree/SchemaTree';
import { useConnectionStore } from '@/stores/connectionStore';
import { useSettingsStore } from '@/stores/settingsStore';
import * as tauri from '@/lib/tauri';
import type { TreeNode, SchemaInfo } from '@/lib/types';

interface TableContextMenuTarget {
  node: TreeNode;
  x: number;
  y: number;
}

interface DatabaseNavigatorProps {
  width: number;
  onWidthChange: (width: number) => void;
  minWidth?: number;
  maxWidth?: number;
  refreshTrigger?: number;
  onCloneTable?: (schema: string, table: string, type: 'table' | 'view') => void;
  onImportData?: (schema: string, table: string) => void;
  onExportData?: (schema: string, table: string, type: 'table' | 'view' | 'foreign-table') => void;
  onViewRows?: (schema: string, table: string, limit: number | null) => void;
}

export function DatabaseNavigator({
  width,
  onWidthChange,
  minWidth = 200,
  maxWidth = 500,
  refreshTrigger,
  onCloneTable,
  onImportData,
  onExportData,
  onViewRows,
}: DatabaseNavigatorProps) {
  const [searchQuery, setSearchQuery] = useState('');
  const [isResizing, setIsResizing] = useState(false);
  const [isSchemaDropdownOpen, setIsSchemaDropdownOpen] = useState(false);
  const [contextMenu, setContextMenu] = useState<TableContextMenuTarget | null>(null);
  const resizerRef = useRef<HTMLDivElement>(null);
  const dropdownRef = useRef<HTMLDivElement>(null);
  const contextMenuRef = useRef<HTMLDivElement>(null);

  const activeConnection = useConnectionStore((state) => state.getActiveConnection());
  const activeConnectionId = useConnectionStore((state) => state.activeConnectionId);
  const selectedSchema = useConnectionStore((state) =>
    activeConnectionId ? state.getSelectedSchema(activeConnectionId) : null
  );
  const setSelectedSchema = useConnectionStore((state) => state.setSelectedSchema);
  const showEmptySchemas = useSettingsStore((state) => state.settings.ui.showEmptySchemas);

  const [schemas, setSchemas] = useState<SchemaInfo[]>([]);
  const [treeNodes, setTreeNodes] = useState<TreeNode[]>([]);
  const [isLoadingSchema, setIsLoadingSchema] = useState(false);

  const handleMouseDown = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault();
      setIsResizing(true);

      const startX = e.clientX;
      const startWidth = width;

      const handleMouseMove = (moveEvent: MouseEvent) => {
        const delta = moveEvent.clientX - startX;
        const newWidth = Math.round(Math.max(minWidth, Math.min(maxWidth, startWidth + delta)));
        onWidthChange(newWidth);
      };

      const handleMouseUp = () => {
        setIsResizing(false);
        document.removeEventListener('mousemove', handleMouseMove);
        document.removeEventListener('mouseup', handleMouseUp);
      };

      document.addEventListener('mousemove', handleMouseMove);
      document.addEventListener('mouseup', handleMouseUp);
    },
    [width, minWidth, maxWidth, onWidthChange]
  );

  // Close dropdown when clicking outside
  useEffect(() => {
    if (!isSchemaDropdownOpen) return;

    const handleClickOutside = (e: MouseEvent) => {
      if (dropdownRef.current && !dropdownRef.current.contains(e.target as Node)) {
        setIsSchemaDropdownOpen(false);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [isSchemaDropdownOpen]);

  // Close context menu when clicking outside
  useEffect(() => {
    if (!contextMenu) return;

    const handleClickOutside = (e: MouseEvent) => {
      if (contextMenuRef.current && !contextMenuRef.current.contains(e.target as Node)) {
        setContextMenu(null);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [contextMenu]);

  const handleNodeContextMenu = useCallback((node: TreeNode, x: number, y: number) => {
    setContextMenu({ node, x, y });
  }, []);

  const handleCloneTable = useCallback(() => {
    if (contextMenu?.node.metadata?.schemaName && contextMenu?.node.metadata?.tableName) {
      onCloneTable?.(
        contextMenu.node.metadata.schemaName,
        contextMenu.node.metadata.tableName,
        contextMenu.node.type as 'table' | 'view'
      );
      setContextMenu(null);
    }
  }, [contextMenu, onCloneTable]);

  const handleImportData = useCallback(() => {
    if (contextMenu?.node.metadata?.schemaName && contextMenu?.node.metadata?.tableName) {
      onImportData?.(
        contextMenu.node.metadata.schemaName,
        contextMenu.node.metadata.tableName
      );
      setContextMenu(null);
    }
  }, [contextMenu, onImportData]);

  const handleExportData = useCallback(() => {
    if (contextMenu?.node.metadata?.schemaName && contextMenu?.node.metadata?.tableName) {
      onExportData?.(
        contextMenu.node.metadata.schemaName,
        contextMenu.node.metadata.tableName,
        contextMenu.node.type as 'table' | 'view' | 'foreign-table'
      );
      setContextMenu(null);
    }
  }, [contextMenu, onExportData]);

  const handleViewRows = useCallback((limit: number | null) => {
    if (contextMenu?.node.metadata?.schemaName && contextMenu?.node.metadata?.tableName) {
      onViewRows?.(
        contextMenu.node.metadata.schemaName,
        contextMenu.node.metadata.tableName,
        limit
      );
      setContextMenu(null);
    }
  }, [contextMenu, onViewRows]);

  const [ddlLoading, setDdlLoading] = useState<string | null>(null);

  const handleCopyCreateTable = useCallback(async () => {
    if (!contextMenu?.node.metadata?.connectionId || !contextMenu?.node.metadata?.schemaName || !contextMenu?.node.metadata?.tableName) return;
    const { connectionId, schemaName, tableName } = contextMenu.node.metadata;
    setDdlLoading('create-table');
    try {
      const ddl = await tauri.generateTableDdl(connectionId, schemaName, tableName);
      await navigator.clipboard.writeText(ddl);
    } catch (err) {
      console.error('Failed to generate DDL:', err);
    } finally {
      setDdlLoading(null);
      setContextMenu(null);
    }
  }, [contextMenu]);

  const handleCopySelectStar = useCallback(() => {
    if (!contextMenu?.node.metadata?.schemaName || !contextMenu?.node.metadata?.tableName) return;
    const { schemaName, tableName } = contextMenu.node.metadata;
    const sql = `SELECT * FROM "${schemaName}"."${tableName}" LIMIT 1000;`;
    navigator.clipboard.writeText(sql);
    setContextMenu(null);
  }, [contextMenu]);

  const handleCopyCreateIndex = useCallback(async () => {
    if (!contextMenu?.node.metadata?.connectionId || !contextMenu?.node.metadata?.schemaName || !contextMenu?.node.metadata?.indexName) return;
    const { connectionId, schemaName, indexName } = contextMenu.node.metadata;
    setDdlLoading('create-index');
    try {
      const ddl = await tauri.generateIndexDdl(connectionId, schemaName, indexName);
      await navigator.clipboard.writeText(ddl);
    } catch (err) {
      console.error('Failed to generate index DDL:', err);
    } finally {
      setDdlLoading(null);
      setContextMenu(null);
    }
  }, [contextMenu]);

  // Build schema tree nodes from fetched schemas and tables
  const buildSchemaNodes = useCallback(async (connectionId: string, fetchedSchemas: SchemaInfo[]) => {
    return Promise.all(
      fetchedSchemas.map(async (schema) => {
        const tables = await tauri.getTables(connectionId, schema.name);

        const tableNodes: TreeNode[] = tables
          .filter((t) => t.tableType === 'table')
          .map((table) => ({
            id: `${connectionId}-${schema.name}-${table.name}`,
            label: table.name,
            type: 'table' as const,
            isExpanded: false,
            children: [],
            metadata: {
              connectionId,
              schemaName: schema.name,
              tableName: table.name,
              rowCountEstimate: table.rowCountEstimate,
              totalSizeBytes: table.totalSizeBytes,
            },
          }));

        const viewNodes: TreeNode[] = tables
          .filter((t) => t.tableType === 'view')
          .map((view) => ({
            id: `${connectionId}-${schema.name}-${view.name}-view`,
            label: view.name,
            type: 'view' as const,
            isExpanded: false,
            children: [],
            metadata: {
              connectionId,
              schemaName: schema.name,
              tableName: view.name,
              rowCountEstimate: view.rowCountEstimate,
            },
          }));

        const foreignTableNodes: TreeNode[] = tables
          .filter((t) => t.tableType === 'foreign-table')
          .map((table) => ({
            id: `${connectionId}-${schema.name}-${table.name}-foreign`,
            label: table.name,
            type: 'foreign-table' as const,
            isExpanded: false,
            children: [],
            metadata: {
              connectionId,
              schemaName: schema.name,
              tableName: table.name,
              rowCountEstimate: table.rowCountEstimate,
            },
          }));

        // Build "Functions" folder for this schema (lazy-loaded)
        const functionsFolder: TreeNode = {
          id: `${connectionId}-${schema.name}-functions`,
          label: 'Functions',
          type: 'functions' as const,
          isExpanded: false,
          children: [],
          metadata: {
            connectionId,
            schemaName: schema.name,
          },
        };

        return {
          id: `${connectionId}-${schema.name}`,
          label: schema.name,
          type: 'schema' as const,
          isExpanded: false,
          children: [...tableNodes, ...viewNodes, ...foreignTableNodes, functionsFolder],
          metadata: {
            connectionId,
            schemaName: schema.name,
          },
        };
      })
    );
  }, []);

  // Update only the row count estimates on existing tree nodes (preserves expand state)
  const updateRowCountEstimates = useCallback(async (
    connectionId: string,
    schemaNames: string[],
    permissionDenied: Map<string, Set<string>>
  ) => {
    // Re-fetch tables for each schema to get updated row counts
    const updatedCounts = new Map<string, number | null>();
    const unavailableNodes = new Set<string>();

    for (const schemaName of schemaNames) {
      try {
        const tables = await tauri.getTables(connectionId, schemaName);
        const denied = permissionDenied.get(schemaName);
        for (const table of tables) {
          const suffix = table.tableType === 'view' ? '-view' : table.tableType === 'foreign-table' ? '-foreign' : '';
          const nodeId = `${connectionId}-${schemaName}-${table.name}${suffix}`;
          updatedCounts.set(nodeId, table.rowCountEstimate ?? null);
          if (denied?.has(table.name)) {
            unavailableNodes.add(nodeId);
          }
        }
      } catch {
        // Ignore errors during background refresh
      }
    }

    if (updatedCounts.size === 0) return;

    setTreeNodes((prev) => {
      const updateNodes = (nodes: TreeNode[]): TreeNode[] =>
        nodes.map((node) => {
          if (updatedCounts.has(node.id)) {
            return {
              ...node,
              metadata: {
                ...node.metadata,
                rowCountEstimate: updatedCounts.get(node.id),
                rowCountUnavailable: unavailableNodes.has(node.id),
              },
            };
          }
          if (node.children) {
            return { ...node, children: updateNodes(node.children) };
          }
          return node;
        });
      return updateNodes(prev);
    });
  }, []);

  const loadSchemaTree = useCallback(async (connectionId: string) => {
    setIsLoadingSchema(true);
    try {
      const fetchedSchemas = await tauri.getSchemas(connectionId);
      const schemaNodes = await buildSchemaNodes(connectionId, fetchedSchemas);

      // Filter out empty schemas unless setting is enabled
      const filteredSchemaNodes = showEmptySchemas
        ? schemaNodes
        : schemaNodes.filter((node) => node.children && node.children.length > 0);

      // Derive schemas list for dropdown from filtered nodes
      const filteredSchemaNames = new Set(filteredSchemaNodes.map((node) => node.label));
      const filteredSchemas = fetchedSchemas.filter((s) => filteredSchemaNames.has(s.name));

      setSchemas(filteredSchemas);
      setTreeNodes(filteredSchemaNodes);

      // Run ANALYZE in background for schemas that have unanalyzed tables,
      // then update just the row count badges without rebuilding the tree
      const schemaNames = filteredSchemaNodes.map((n) => n.label);
      Promise.all(
        schemaNames.map((name) =>
          tauri.analyzeSchema(connectionId, name).catch(() => ({
            hadUnanalyzed: false,
            permissionDeniedTables: [] as string[],
          }))
        )
      ).then((results) => {
        const analyzedSchemas: string[] = [];
        const permissionDenied = new Map<string, Set<string>>();

        results.forEach((result, i) => {
          if (result.hadUnanalyzed) {
            analyzedSchemas.push(schemaNames[i]);
          }
          if (result.permissionDeniedTables.length > 0) {
            permissionDenied.set(schemaNames[i], new Set(result.permissionDeniedTables));
            // Also include schemas with permission-denied tables for re-fetch
            if (!result.hadUnanalyzed) {
              analyzedSchemas.push(schemaNames[i]);
            }
          }
        });

        if (analyzedSchemas.length > 0) {
          updateRowCountEstimates(connectionId, analyzedSchemas, permissionDenied);
        }
      });
    } catch (err) {
      console.error('Failed to load schema:', err);
    } finally {
      setIsLoadingSchema(false);
    }
  }, [showEmptySchemas, buildSchemaNodes, updateRowCountEstimates]);

  const loadTableColumns = useCallback(async (node: TreeNode) => {
    if (!node.metadata?.connectionId || !node.metadata?.schemaName || !node.metadata?.tableName) {
      return;
    }

    const { connectionId, schemaName, tableName } = node.metadata;

    try {
      // Load columns, indexes, and constraints in parallel
      const [columns, indexes, constraints] = await Promise.all([
        tauri.getColumns(connectionId, schemaName, tableName),
        tauri.getTableIndexes(connectionId, schemaName, tableName),
        tauri.getTableConstraints(connectionId, schemaName, tableName),
      ]);

      const columnNodes: TreeNode[] = columns.map((col) => ({
        id: `${connectionId}-${schemaName}-${tableName}-${col.name}`,
        label: col.name,
        type: 'column' as const,
        metadata: {
          dataType: col.dataType,
          isPrimaryKey: col.isPrimaryKey,
          connectionId,
          schemaName,
          tableName,
        },
      }));

      // Build indexes folder
      const indexNodes: TreeNode[] = indexes.map((idx) => ({
        id: `${connectionId}-${schemaName}-${tableName}-idx-${idx.name}`,
        label: `${idx.name} (${idx.columns.join(', ')})`,
        type: 'index' as const,
        metadata: {
          connectionId,
          schemaName,
          tableName,
          indexName: idx.name,
          indexType: idx.indexType,
          isUnique: idx.isUnique,
          isPrimaryKey: idx.isPrimary,
          sizeBytes: idx.sizeBytes,
        },
      }));

      const indexesFolder: TreeNode | null = indexNodes.length > 0 ? {
        id: `${connectionId}-${schemaName}-${tableName}-indexes`,
        label: `Indexes (${indexNodes.length})`,
        type: 'indexes' as const,
        isExpanded: false,
        children: indexNodes,
        metadata: { connectionId, schemaName, tableName },
      } : null;

      // Build constraints folder
      const constraintNodes: TreeNode[] = constraints.map((con) => {
        let label = con.name;
        if (con.constraintType === 'FOREIGN KEY' && con.referencedTable) {
          label = `${con.name} → ${con.referencedTable}`;
        }
        return {
          id: `${connectionId}-${schemaName}-${tableName}-con-${con.name}`,
          label,
          type: 'constraint' as const,
          metadata: {
            constraintType: con.constraintType,
            referencedTable: con.referencedTable ?? undefined,
          },
        };
      });

      const constraintsFolder: TreeNode | null = constraintNodes.length > 0 ? {
        id: `${connectionId}-${schemaName}-${tableName}-constraints`,
        label: `Constraints (${constraintNodes.length})`,
        type: 'constraints' as const,
        isExpanded: false,
        children: constraintNodes,
        metadata: { connectionId, schemaName, tableName },
      } : null;

      const children: TreeNode[] = [
        ...columnNodes,
        ...(indexesFolder ? [indexesFolder] : []),
        ...(constraintsFolder ? [constraintsFolder] : []),
      ];

      setTreeNodes((prev) => {
        const updateChildren = (nodes: TreeNode[]): TreeNode[] => {
          return nodes.map((n) => {
            if (n.id === node.id) {
              return { ...n, children, isExpanded: true };
            }
            if (n.children) {
              return { ...n, children: updateChildren(n.children) };
            }
            return n;
          });
        };
        return updateChildren(prev);
      });
    } catch (err) {
      console.error('Failed to load columns:', err);
    }
  }, []);

  const loadSchemaFunctions = useCallback(async (node: TreeNode) => {
    if (!node.metadata?.connectionId || !node.metadata?.schemaName) return;

    const { connectionId, schemaName } = node.metadata;

    try {
      const functions = await tauri.getSchemaFunctions(connectionId, schemaName);

      const functionNodes: TreeNode[] = functions.map((fn) => ({
        id: `${connectionId}-${schemaName}-fn-${fn.name}-${fn.argumentTypes}`,
        label: `${fn.name}(${fn.argumentTypes})`,
        type: (fn.functionType === 'procedure' ? 'procedure' : 'function') as 'function' | 'procedure',
        metadata: {
          returnType: fn.returnType,
          argumentTypes: fn.argumentTypes,
          language: fn.language,
          schemaName,
        },
      }));

      setTreeNodes((prev) => {
        const updateChildren = (nodes: TreeNode[]): TreeNode[] => {
          return nodes.map((n) => {
            if (n.id === node.id) {
              return { ...n, children: functionNodes, isExpanded: true };
            }
            if (n.children) {
              return { ...n, children: updateChildren(n.children) };
            }
            return n;
          });
        };
        return updateChildren(prev);
      });
    } catch (err) {
      console.error('Failed to load functions:', err);
    }
  }, []);

  const handleNodeExpand = useCallback(
    async (node: TreeNode) => {
      // Lazy-load columns, indexes, constraints for tables
      if (
        (node.type === 'table' || node.type === 'view' || node.type === 'foreign-table') &&
        node.children?.length === 0 &&
        !node.isExpanded
      ) {
        await loadTableColumns(node);
        return;
      }

      // Lazy-load functions
      if (
        node.type === 'functions' &&
        node.children?.length === 0 &&
        !node.isExpanded
      ) {
        await loadSchemaFunctions(node);
        return;
      }

      setTreeNodes((prev) => {
        const toggleExpand = (nodes: TreeNode[]): TreeNode[] => {
          return nodes.map((n) => {
            if (n.id === node.id) {
              return { ...n, isExpanded: !n.isExpanded };
            }
            if (n.children) {
              return { ...n, children: toggleExpand(n.children) };
            }
            return n;
          });
        };
        return toggleExpand(prev);
      });
    },
    [loadTableColumns, loadSchemaFunctions]
  );

  // Load schema when connected or when refresh trigger changes
  useEffect(() => {
    if (activeConnection?.status === 'connected') {
      loadSchemaTree(activeConnection.config.id);
    } else {
      setTreeNodes([]);
      setSchemas([]);
    }
  }, [activeConnection?.config.id, activeConnection?.status, loadSchemaTree, refreshTrigger]);

  // Auto-select 'public' schema if it's the only one with tables
  useEffect(() => {
    if (
      activeConnectionId &&
      selectedSchema === null &&
      schemas.length === 1 &&
      schemas[0].name === 'public'
    ) {
      setSelectedSchema(activeConnectionId, 'public');
    }
  }, [activeConnectionId, selectedSchema, schemas, setSelectedSchema]);

  // Filter tree nodes based on selected schema and search query
  const filteredTreeNodes = useMemo(() => {
    let filtered = treeNodes;

    // Filter by selected schema
    if (selectedSchema) {
      filtered = filtered.filter((node) => node.metadata?.schemaName === selectedSchema);
    }

    // Filter by search query
    if (searchQuery.trim()) {
      const query = searchQuery.toLowerCase();
      filtered = filtered
        .map((schemaNode) => {
          const matchingChildren = schemaNode.children?.filter(
            (child) =>
              child.label.toLowerCase().includes(query) ||
              child.children?.some((col) => col.label.toLowerCase().includes(query))
          );
          if (matchingChildren && matchingChildren.length > 0) {
            return { ...schemaNode, children: matchingChildren, isExpanded: true };
          }
          if (schemaNode.label.toLowerCase().includes(query)) {
            return schemaNode;
          }
          return null;
        })
        .filter(Boolean) as TreeNode[];
    }

    return filtered;
  }, [treeNodes, selectedSchema, searchQuery]);

  // Display nodes: if a schema is selected, show tables directly; otherwise show schema nodes
  const displayNodes = useMemo(() => {
    if (selectedSchema) {
      // Show tables directly without schema wrapper
      return filteredTreeNodes.flatMap((node) => node.children || []);
    }
    return filteredTreeNodes;
  }, [selectedSchema, filteredTreeNodes]);

  return (
    <div
      className="flex flex-col bg-theme-bg-surface border-r border-theme-border-primary relative"
      style={{ width }}
    >
      {/* Database name header */}
      {activeConnection && (
        <div className="px-2.5 py-1.5 border-b border-theme-border-primary">
          <div className="flex items-center gap-1.5">
            <Database className="w-3.5 h-3.5 text-theme-text-tertiary" />
            <span className="text-xs font-medium text-theme-text-primary truncate">
              {activeConnection.config.database}
            </span>
          </div>
        </div>
      )}

      {/* Schema dropdown */}
      {activeConnection?.status === 'connected' && schemas.length > 0 && (
        <div className="px-2 py-1.5" ref={dropdownRef}>
          <button
            onClick={() => setIsSchemaDropdownOpen(!isSchemaDropdownOpen)}
            className={cn(
              'w-full flex items-center justify-between px-2 py-1 rounded-md',
              'bg-theme-bg-elevated border border-theme-border-primary',
              'text-xs text-theme-text-primary',
              'hover:bg-theme-bg-hover transition-colors'
            )}
          >
            <span className="truncate">
              {selectedSchema || 'All Schemas'}
            </span>
            <ChevronDown
              className={cn(
                'w-3.5 h-3.5 text-theme-text-tertiary transition-transform',
                isSchemaDropdownOpen && 'rotate-180'
              )}
            />
          </button>

          {isSchemaDropdownOpen && activeConnectionId && (
            <div className="absolute left-2 right-2 mt-1 z-20 py-0.5 bg-theme-bg-elevated border border-theme-border-secondary rounded-md shadow-xl max-h-64 overflow-y-auto">
              <button
                onClick={() => {
                  setSelectedSchema(activeConnectionId, null);
                  setIsSchemaDropdownOpen(false);
                }}
                className={cn(
                  'w-full text-left px-2 py-1 text-xs hover:bg-theme-bg-hover transition-colors',
                  !selectedSchema ? 'text-theme-text-primary bg-theme-bg-active' : 'text-theme-text-secondary'
                )}
              >
                All Schemas
              </button>
              {schemas.map((schema) => (
                <button
                  key={schema.name}
                  onClick={() => {
                    setSelectedSchema(activeConnectionId, schema.name);
                    setIsSchemaDropdownOpen(false);
                  }}
                  className={cn(
                    'w-full text-left px-2 py-1 text-xs hover:bg-theme-bg-hover transition-colors',
                    selectedSchema === schema.name ? 'text-theme-text-primary bg-theme-bg-active' : 'text-theme-text-secondary'
                  )}
                >
                  {schema.name}
                </button>
              ))}
            </div>
          )}
        </div>
      )}

      {/* Search bar */}
      <div className="px-2 py-1.5">
        <div className="relative">
          <Search className="absolute left-2 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-theme-text-tertiary" />
          <input
            type="text"
            placeholder="Search tables..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className={cn(
              'w-full pl-7 pr-2 py-1 rounded-md',
              'bg-theme-bg-elevated border border-theme-border-primary',
              'text-xs text-theme-text-primary placeholder-theme-text-muted',
              'focus:outline-none focus:border-theme-border-secondary',
              'transition-colors duration-200'
            )}
          />
        </div>
      </div>

      {/* Tree view */}
      <div className="flex-1 overflow-y-auto">
        {!activeConnection ? (
          <div className="flex flex-col items-center justify-center h-32 text-theme-text-tertiary text-sm p-4 text-center">
            <p>Click a server to connect</p>
          </div>
        ) : activeConnection.status === 'connecting' ? (
          <div className="flex items-center justify-center h-32 text-theme-text-tertiary text-sm">
            <RefreshCw className="w-4 h-4 animate-spin mr-2" />
            Connecting...
          </div>
        ) : activeConnection.status === 'error' ? (
          <div className="flex flex-col items-center justify-center h-32 text-red-400 text-sm p-4 text-center">
            <p>Connection failed</p>
            {activeConnection.error && (
              <p className="text-xs text-red-400/70 mt-1">{activeConnection.error}</p>
            )}
          </div>
        ) : activeConnection.status !== 'connected' ? (
          <div className="flex flex-col items-center justify-center h-32 text-theme-text-tertiary text-sm p-4 text-center">
            <p>Click server icon to connect</p>
          </div>
        ) : isLoadingSchema ? (
          <div className="flex items-center justify-center h-32 text-theme-text-tertiary text-sm">
            <RefreshCw className="w-4 h-4 animate-spin mr-2" />
            Loading schema...
          </div>
        ) : (
          <SchemaTree
            nodes={displayNodes}
            onNodeExpand={handleNodeExpand}
            onNodeContextMenu={handleNodeContextMenu}
            showSchemaInLabel={!selectedSchema}
          />
        )}
      </div>

      {/* Context Menu */}
      {contextMenu && (
        <div
          ref={contextMenuRef}
          className="fixed z-50 min-w-[160px] py-1 bg-theme-bg-elevated border border-theme-border-secondary rounded-lg shadow-xl"
          style={{ left: contextMenu.x, top: contextMenu.y }}
        >
          {/* Column context menu */}
          {contextMenu.node.type === 'column' && (
            <>
              <button
                className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
                onClick={() => {
                  navigator.clipboard.writeText(contextMenu.node.label);
                  setContextMenu(null);
                }}
              >
                <ClipboardCopy className="w-4 h-4" />
                Copy Column Name
              </button>
              <button
                className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
                onClick={() => {
                  const { schemaName, tableName } = contextMenu.node.metadata || {};
                  const qualified = [schemaName, tableName, contextMenu.node.label].filter(Boolean).join('.');
                  navigator.clipboard.writeText(qualified);
                  setContextMenu(null);
                }}
              >
                <Copy className="w-4 h-4" />
                Copy Qualified Name
              </button>
            </>
          )}
          {/* View rows options for tables, views, and foreign tables */}
          {(contextMenu.node.type === 'table' || contextMenu.node.type === 'view' || contextMenu.node.type === 'foreign-table') && (
            <>
              <button
                className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
                onClick={() => handleViewRows(1000)}
              >
                <Table className="w-4 h-4" />
                View 1000 Rows
              </button>
              <button
                className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
                onClick={() => handleViewRows(null)}
              >
                <Eye className="w-4 h-4" />
                View All Rows
              </button>
              <div className="my-1 border-t border-theme-border-primary" />
            </>
          )}
          {contextMenu.node.type === 'table' && (
            <>
              <button
                className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
                onClick={handleCloneTable}
              >
                <Copy className="w-4 h-4" />
                Clone Table
              </button>
              <button
                className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
                onClick={handleImportData}
              >
                <Upload className="w-4 h-4" />
                Import Data
              </button>
            </>
          )}
          {(contextMenu.node.type === 'table' || contextMenu.node.type === 'view' || contextMenu.node.type === 'foreign-table') && (
            <button
              className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
              onClick={handleExportData}
            >
              <Download className="w-4 h-4" />
              Export Data
            </button>
          )}
          {(contextMenu.node.type === 'table' || contextMenu.node.type === 'view' || contextMenu.node.type === 'foreign-table') && (
            <>
              <div className="my-1 border-t border-theme-border-primary" />
              <button
                className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
                onClick={handleCopyCreateTable}
                disabled={ddlLoading === 'create-table'}
              >
                {ddlLoading === 'create-table' ? (
                  <Loader2 className="w-4 h-4 animate-spin" />
                ) : (
                  <Code className="w-4 h-4" />
                )}
                Copy CREATE TABLE
              </button>
              <button
                className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
                onClick={handleCopySelectStar}
              >
                <ClipboardCopy className="w-4 h-4" />
                Copy SELECT *
              </button>
            </>
          )}
          {/* Index context menu */}
          {contextMenu.node.type === 'index' && (
            <button
              className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
              onClick={handleCopyCreateIndex}
              disabled={ddlLoading === 'create-index'}
            >
              {ddlLoading === 'create-index' ? (
                <Loader2 className="w-4 h-4 animate-spin" />
              ) : (
                <Code className="w-4 h-4" />
              )}
              Copy CREATE INDEX
            </button>
          )}
        </div>
      )}

      {/* Resize handle */}
      <div
        ref={resizerRef}
        onMouseDown={handleMouseDown}
        className={cn(
          'absolute right-0 top-0 bottom-0 w-1 cursor-col-resize transition-colors',
          'hover:bg-theme-bg-active',
          isResizing && 'bg-theme-bg-active'
        )}
      />
    </div>
  );
}
