import { useState, useRef, useCallback, useEffect, useMemo } from 'react';
import { Search, ChevronDown, RefreshCw, Database } from 'lucide-react';
import { cn } from '@/lib/cn';
import { SchemaTree } from '@/components/tree/SchemaTree';
import { useConnectionStore } from '@/stores/connectionStore';
import * as tauri from '@/lib/tauri';
import type { TreeNode, SchemaInfo } from '@/lib/types';

interface DatabaseNavigatorProps {
  width: number;
  onWidthChange: (width: number) => void;
  minWidth?: number;
  maxWidth?: number;
  refreshTrigger?: number;
}

export function DatabaseNavigator({
  width,
  onWidthChange,
  minWidth = 200,
  maxWidth = 500,
  refreshTrigger,
}: DatabaseNavigatorProps) {
  const [searchQuery, setSearchQuery] = useState('');
  const [isResizing, setIsResizing] = useState(false);
  const [isSchemaDropdownOpen, setIsSchemaDropdownOpen] = useState(false);
  const resizerRef = useRef<HTMLDivElement>(null);
  const dropdownRef = useRef<HTMLDivElement>(null);

  const activeConnection = useConnectionStore((state) => state.getActiveConnection());
  const activeConnectionId = useConnectionStore((state) => state.activeConnectionId);
  const selectedSchema = useConnectionStore((state) =>
    activeConnectionId ? state.getSelectedSchema(activeConnectionId) : null
  );
  const setSelectedSchema = useConnectionStore((state) => state.setSelectedSchema);

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

  const loadSchemaTree = useCallback(async (connectionId: string) => {
    setIsLoadingSchema(true);
    try {
      const fetchedSchemas = await tauri.getSchemas(connectionId);
      setSchemas(fetchedSchemas);

      const schemaNodes: TreeNode[] = await Promise.all(
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
              },
            }));

          return {
            id: `${connectionId}-${schema.name}`,
            label: schema.name,
            type: 'schema' as const,
            isExpanded: false,
            children: [...tableNodes, ...viewNodes],
            metadata: {
              connectionId,
              schemaName: schema.name,
            },
          };
        })
      );

      setTreeNodes(schemaNodes);
    } catch (err) {
      console.error('Failed to load schema:', err);
    } finally {
      setIsLoadingSchema(false);
    }
  }, []);

  const loadTableColumns = useCallback(async (node: TreeNode) => {
    if (!node.metadata?.connectionId || !node.metadata?.schemaName || !node.metadata?.tableName) {
      return;
    }

    const { connectionId, schemaName, tableName } = node.metadata;

    try {
      const columns = await tauri.getColumns(connectionId, schemaName, tableName);

      const columnNodes: TreeNode[] = columns.map((col) => ({
        id: `${connectionId}-${schemaName}-${tableName}-${col.name}`,
        label: col.name,
        type: 'column' as const,
        metadata: {
          dataType: col.dataType,
          isPrimaryKey: col.isPrimaryKey,
        },
      }));

      setTreeNodes((prev) => {
        const updateChildren = (nodes: TreeNode[]): TreeNode[] => {
          return nodes.map((n) => {
            if (n.id === node.id) {
              return { ...n, children: columnNodes, isExpanded: true };
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

  const handleNodeExpand = useCallback(
    async (node: TreeNode) => {
      if (
        (node.type === 'table' || node.type === 'view') &&
        node.children?.length === 0 &&
        !node.isExpanded
      ) {
        await loadTableColumns(node);
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
    [loadTableColumns]
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
            showSchemaInLabel={!selectedSchema}
          />
        )}
      </div>

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
