import { useState, useRef, useCallback, useEffect, useMemo } from 'react';
import {
  Database,
  ChevronDown,
  RefreshCw,
  Power,
  PowerOff,
  Sidebar as SidebarIcon,
  PanelLeftClose,
  PanelLeftOpen,
  Plus,
  Loader2,
  Trash2,
  Pencil,
  Search,
  Copy,
  Upload,
  Download,
  Table,
  Eye,
  ClipboardCopy,
  Code
} from 'lucide-react';
import { cn } from '@/lib/cn';
import { useConnectionStore } from '@/stores/connectionStore';
import { useSettingsStore } from '@/stores/settingsStore';
import { SchemaTree } from '@/components/tree/SchemaTree';
import * as tauri from '@/lib/tauri';
import type { TreeNode, SchemaInfo, Connection } from '@/lib/types';
import { useContextMenuPosition } from '@/hooks/useContextMenuPosition';

interface SidebarProps {
  width: number;
  onWidthChange: (width: number) => void;
  isCollapsed: boolean;
  onToggleCollapse: () => void;
  onAddConnection: () => void;
  onEditConnection: (connection: Connection) => void;
  schemaRefreshTrigger: number;
  onCloneTable?: (schema: string, table: string, type: 'table' | 'view') => void;
  onImportData?: (schema: string, table: string) => void;
  onExportData?: (schema: string, table: string, type: 'table' | 'view' | 'foreign-table') => void;
  onViewRows?: (schema: string, table: string, limit: number | null) => void;
}

interface TableContextMenuTarget {
  node: TreeNode;
  x: number;
  y: number;
}

export function Sidebar({
  width,
  onWidthChange,
  isCollapsed,
  onToggleCollapse,
  onAddConnection,
  onEditConnection,
  schemaRefreshTrigger,
  onCloneTable,
  onImportData,
  onExportData,
  onViewRows,
}: SidebarProps) {
  const [isResizing, setIsResizing] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');

  // Connection state
  const [isConnectionDropdownOpen, setIsConnectionDropdownOpen] = useState(false);
  const activeConnectionId = useConnectionStore((state) => state.activeConnectionId);
  const setActiveConnection = useConnectionStore((state) => state.setActiveConnection);
  const connections = useConnectionStore((state) => state.connections);
  const connectionOrder = useConnectionStore((state) => state.connectionOrder);
  const updateConnectionStatus = useConnectionStore((state) => state.updateConnectionStatus);
  const setSelectedSchema = useConnectionStore((state) => state.setSelectedSchema);
  const selectedSchemas = useConnectionStore((state) => state.selectedSchemas);
  const showEmptySchemas = useSettingsStore((state) => state.settings.ui.showEmptySchemas);

  // Derived state
  const activeConnection = activeConnectionId ? connections[activeConnectionId] : null;
  const selectedSchema = activeConnectionId ? (selectedSchemas[activeConnectionId] ?? null) : null;

  const orderedConnections = useMemo(() =>
    connectionOrder.map(id => connections[id]).filter(Boolean),
    [connections, connectionOrder]
  );

  // Schema state
  const [isSchemaDropdownOpen, setIsSchemaDropdownOpen] = useState(false);
  const [schemas, setSchemas] = useState<SchemaInfo[]>([]);
  const [treeNodes, setTreeNodes] = useState<TreeNode[]>([]);
  const [isLoadingSchema, setIsLoadingSchema] = useState(false);

  // Context Menu State
  const [contextMenu, setContextMenu] = useState<TableContextMenuTarget | null>(null);
  const [ddlLoading, setDdlLoading] = useState<string | null>(null);

  // Refs
  const connectionDropdownRef = useRef<HTMLDivElement>(null);
  const schemaDropdownRef = useRef<HTMLDivElement>(null);
  const resizerRef = useRef<HTMLDivElement>(null);
  const contextMenuRef = useRef<HTMLDivElement>(null);
  const contextMenuPositionRef = useContextMenuPosition(contextMenu?.x, contextMenu?.y, contextMenuRef);

  // --- Handlers ---

  const handleMouseDown = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    setIsResizing(true);
    const startX = e.clientX;
    const startWidth = width;

    const handleMouseMove = (moveEvent: MouseEvent) => {
      const delta = moveEvent.clientX - startX;
      const newWidth = Math.round(Math.max(200, Math.min(600, startWidth + delta)));
      onWidthChange(newWidth);
    };

    const handleMouseUp = () => {
      setIsResizing(false);
      document.removeEventListener('mousemove', handleMouseMove);
      document.removeEventListener('mouseup', handleMouseUp);
    };

    document.addEventListener('mousemove', handleMouseMove);
    document.addEventListener('mouseup', handleMouseUp);
  }, [width, onWidthChange]);

  const handleConnect = useCallback(async (connection: Connection) => {
    updateConnectionStatus(connection.config.id, 'connecting');
    try {
      const result = await tauri.connectPostgres(connection.config.id);
      if (result.status === 'connected') {
        updateConnectionStatus(connection.config.id, 'connected', undefined, result.latency_ms);
      } else if (result.status === 'error') {
        updateConnectionStatus(connection.config.id, 'error', result.error || 'Connection failed');
      } else {
        updateConnectionStatus(connection.config.id, result.status);
      }
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : String(err);
      updateConnectionStatus(connection.config.id, 'error', errorMessage);
    }
  }, [updateConnectionStatus]);

  // --- Schema Tree Logic ---

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

  // Update only the row count estimates
  const updateRowCountEstimates = useCallback(async (
    connectionId: string,
    schemaNames: string[],
    permissionDenied: Map<string, Set<string>>
  ) => {
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
        // Ignore
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

      const filteredSchemaNames = new Set(filteredSchemaNodes.map((node) => node.label));
      const filteredSchemas = fetchedSchemas.filter((s) => filteredSchemaNames.has(s.name));

      setSchemas(filteredSchemas);
      setTreeNodes(filteredSchemaNodes);

      // Run ANALYZE in background
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
    if (!node.metadata?.connectionId || !node.metadata?.schemaName || !node.metadata?.tableName) return;
    const { connectionId, schemaName, tableName } = node.metadata;

    try {
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

  const handleNodeExpand = useCallback(async (node: TreeNode) => {
    if (
      (node.type === 'table' || node.type === 'view' || node.type === 'foreign-table') &&
      node.children?.length === 0 &&
      !node.isExpanded
    ) {
      await loadTableColumns(node);
      return;
    }
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
  }, [loadTableColumns, loadSchemaFunctions]);

  // Trigger schema load
  useEffect(() => {
    if (activeConnectionId && connections[activeConnectionId]?.status === 'connected') {
      loadSchemaTree(activeConnectionId);
    } else {
      setTreeNodes([]);
      setSchemas([]);
    }
  }, [activeConnectionId, connections[activeConnectionId]?.status, schemaRefreshTrigger, loadSchemaTree]);

  // Auto-select 'public' schema if it's the only one
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

  // Filter tree nodes
  const filteredTreeNodes = useMemo(() => {
    let filtered = treeNodes;
    if (selectedSchema) {
      filtered = filtered.filter((node) => node.metadata?.schemaName === selectedSchema);
    }
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

  const displayNodes = useMemo(() => {
    if (selectedSchema) {
      return filteredTreeNodes.flatMap((node) => node.children || []);
    }
    return filteredTreeNodes;
  }, [selectedSchema, filteredTreeNodes]);

  // --- Context Menu Handlers ---

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

  // Close dropdowns logic
  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      if (connectionDropdownRef.current && !connectionDropdownRef.current.contains(e.target as Node)) {
        setIsConnectionDropdownOpen(false);
      }
      if (schemaDropdownRef.current && !schemaDropdownRef.current.contains(e.target as Node)) {
        setIsSchemaDropdownOpen(false);
      }
      if (contextMenuRef.current && !contextMenuRef.current.contains(e.target as Node)) {
        setContextMenu(null);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  return (
    <div
      className={cn(
        "flex flex-col h-full relative transition-all duration-300 ease-in-out bg-glass border-r border-theme-border-primary backdrop-blur-md",
        isCollapsed ? "w-[60px]" : "w-64"
      )}
      style={!isCollapsed ? { width } : undefined}
    >
      {/* Traffic Lights Spacer / Drag Region */}
      <div
        data-tauri-drag-region
        className="h-[38px] w-full flex-shrink-0 flex items-center justify-center border-b border-transparent select-none"
      >
          {isCollapsed && (
             <div className="text-theme-text-tertiary">
                <Database className="w-4 h-4" />
             </div>
          )}
      </div>

      {!isCollapsed ? (
        <div className="flex-1 flex flex-col min-h-0 overflow-hidden">
            {/* Header */}
            <div className="px-3 py-3 space-y-3 flex-shrink-0">
                {/* Connection Selector */}
                <div className="relative" ref={connectionDropdownRef}>
                    <button
                        onClick={() => setIsConnectionDropdownOpen(!isConnectionDropdownOpen)}
                        className="w-full flex items-center justify-between px-2 py-1.5 rounded-md bg-theme-bg-active/30 hover:bg-theme-bg-active/50 border border-theme-border-primary text-xs transition-colors"
                    >
                        <div className="flex items-center gap-2 truncate">
                            {activeConnection ? (
                                <>
                                    <div className={cn("w-2 h-2 rounded-full", activeConnection.status === 'connected' ? "bg-theme-status-connected" : "bg-theme-status-disconnected")} />
                                    <span className="font-medium truncate">{activeConnection.config.name}</span>
                                </>
                            ) : (
                                <span className="text-theme-text-muted">Select Connection</span>
                            )}
                        </div>
                        <ChevronDown className="w-3.5 h-3.5 text-theme-text-tertiary" />
                    </button>

                    {isConnectionDropdownOpen && (
                        <div className="absolute left-0 right-0 top-full mt-1 z-50 bg-theme-bg-elevated border border-theme-border-secondary rounded-lg shadow-xl py-1 max-h-60 overflow-y-auto">
                            {orderedConnections.map(conn => (
                                <div
                                    key={conn.config.id}
                                    className="flex items-center justify-between px-2 py-1.5 hover:bg-theme-bg-hover cursor-pointer"
                                    onClick={() => {
                                        setActiveConnection(conn.config.id);
                                        setIsConnectionDropdownOpen(false);
                                        if (conn.status !== 'connected') handleConnect(conn);
                                    }}
                                >
                                    <div className="flex items-center gap-2 truncate">
                                        <div className={cn("w-2 h-2 rounded-full", conn.status === 'connected' ? "bg-theme-status-connected" : "bg-theme-status-disconnected")} />
                                        <span className={cn("text-xs truncate", activeConnectionId === conn.config.id ? "text-theme-text-primary" : "text-theme-text-secondary")}>
                                            {conn.config.name}
                                        </span>
                                    </div>
                                    {activeConnectionId === conn.config.id && (
                                        <div className="w-1.5 h-1.5 rounded-full bg-theme-accent" />
                                    )}
                                </div>
                            ))}
                            <div className="border-t border-theme-border-primary my-1" />
                            <button
                                onClick={() => { setIsConnectionDropdownOpen(false); onAddConnection(); }}
                                className="w-full flex items-center gap-2 px-2 py-1.5 text-xs text-theme-text-secondary hover:text-theme-text-primary hover:bg-theme-bg-hover"
                            >
                                <Plus className="w-3.5 h-3.5" />
                                New Connection
                            </button>
                        </div>
                    )}
                </div>

                {/* Schema Selector */}
                {activeConnection?.status === 'connected' && (
                    <div className="relative" ref={schemaDropdownRef}>
                        <button
                            onClick={() => setIsSchemaDropdownOpen(!isSchemaDropdownOpen)}
                            className="w-full flex items-center justify-between px-2 py-1.5 rounded-md bg-transparent hover:bg-theme-bg-hover border border-theme-border-primary text-xs transition-colors"
                        >
                            <span className="truncate">{selectedSchema || "All Schemas"}</span>
                            <ChevronDown className="w-3.5 h-3.5 text-theme-text-tertiary" />
                        </button>
                         {isSchemaDropdownOpen && (
                            <div className="absolute left-0 right-0 top-full mt-1 z-50 bg-theme-bg-elevated border border-theme-border-secondary rounded-lg shadow-xl py-1 max-h-48 overflow-y-auto">
                                <button
                                    onClick={() => { setSelectedSchema(activeConnectionId!, null); setIsSchemaDropdownOpen(false); }}
                                    className={cn("w-full text-left px-2 py-1.5 text-xs hover:bg-theme-bg-hover", !selectedSchema && "text-theme-accent bg-theme-bg-active/20")}
                                >
                                    All Schemas
                                </button>
                                {schemas.map(s => (
                                    <button
                                        key={s.name}
                                        onClick={() => { setSelectedSchema(activeConnectionId!, s.name); setIsSchemaDropdownOpen(false); }}
                                        className={cn("w-full text-left px-2 py-1.5 text-xs hover:bg-theme-bg-hover", selectedSchema === s.name && "text-theme-accent bg-theme-bg-active/20")}
                                    >
                                        {s.name}
                                    </button>
                                ))}
                            </div>
                        )}
                    </div>
                )}

                {/* Search Bar */}
                {activeConnection?.status === 'connected' && (
                    <div className="relative">
                        <Search className="absolute left-2 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-theme-text-tertiary" />
                        <input
                            type="text"
                            placeholder="Search tables..."
                            value={searchQuery}
                            onChange={(e) => setSearchQuery(e.target.value)}
                            className={cn(
                                'w-full pl-7 pr-2 py-1 rounded-md',
                                'bg-theme-bg-elevated/50 border border-theme-border-primary',
                                'text-xs text-theme-text-primary placeholder-theme-text-muted',
                                'focus:outline-none focus:border-theme-border-secondary',
                                'transition-colors duration-200'
                            )}
                        />
                    </div>
                )}
            </div>

            {/* Tree View */}
            <div className="flex-1 overflow-y-auto px-1 pb-2 scrollbar-thin">
                {isLoadingSchema ? (
                    <div className="flex items-center justify-center p-4 text-theme-text-tertiary">
                        <Loader2 className="w-4 h-4 animate-spin" />
                    </div>
                ) : treeNodes.length > 0 ? (
                    <SchemaTree
                        nodes={displayNodes}
                        showSchemaInLabel={!selectedSchema}
                        onNodeExpand={handleNodeExpand}
                        onNodeContextMenu={handleNodeContextMenu}
                    />
                ) : (
                    <div className="text-center p-4 text-xs text-theme-text-muted">
                        {activeConnection?.status === 'connected' ? "No tables found" : "Connect to view schema"}
                    </div>
                )}
            </div>

            {/* Collapse Toggle */}
            <div className="p-2 border-t border-theme-border-primary flex justify-end bg-theme-bg-active/10">
                <button
                    onClick={onToggleCollapse}
                    className="p-1.5 rounded-md hover:bg-theme-bg-hover text-theme-text-tertiary transition-colors"
                    title="Collapse Sidebar"
                >
                    <PanelLeftClose className="w-4 h-4" />
                </button>
            </div>
        </div>
      ) : (
        /* Collapsed View */
        <div className="flex-1 flex flex-col items-center pt-4">
             <button
                onClick={onToggleCollapse}
                className="p-2 rounded-md hover:bg-theme-bg-hover text-theme-text-secondary transition-colors"
                title="Expand Sidebar"
             >
                <PanelLeftOpen className="w-5 h-5" />
             </button>
        </div>
      )}

      {/* Resize Handle */}
      <div
        ref={resizerRef}
        onMouseDown={!isCollapsed ? handleMouseDown : undefined}
        className={cn(
          "absolute right-0 top-0 bottom-0 w-1 cursor-col-resize hover:bg-theme-border-secondary transition-colors z-10",
          isResizing && "bg-theme-accent w-1.5"
        )}
      />

      {/* Context Menu */}
      {contextMenu && (
        <div
          ref={contextMenuPositionRef}
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
          {/* View rows options */}
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
    </div>
  );
}
