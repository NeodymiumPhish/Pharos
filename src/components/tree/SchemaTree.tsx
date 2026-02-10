import { useCallback } from 'react';
import {
  ChevronRight,
  ChevronDown,
  Database,
  Folder,
  Table,
  Eye,
  Key,
  Type,
  Globe,
  ListTree,
  Link,
  FunctionSquare,
} from 'lucide-react';
import { cn } from '@/lib/cn';
import type { TreeNode, TreeNodeType } from '@/lib/types';

function formatRowCount(count: number | null | undefined): string | null {
  if (count == null || count < 0) return null;
  if (count < 1000) return `${count}`;
  if (count < 1_000_000) return `${(count / 1000).toFixed(count < 10_000 ? 1 : 0)}K`;
  if (count < 1_000_000_000) return `${(count / 1_000_000).toFixed(count < 10_000_000 ? 1 : 0)}M`;
  return `${(count / 1_000_000_000).toFixed(1)}B`;
}

function formatBytes(bytes: number | null | undefined): string | null {
  if (bytes == null || bytes < 0) return null;
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(bytes < 10240 ? 1 : 0)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(bytes < 10 * 1024 * 1024 ? 1 : 0)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}

interface SchemaTreeProps {
  nodes: TreeNode[];
  onNodeExpand?: (node: TreeNode) => void;
  onNodeSelect?: (node: TreeNode) => void;
  onNodeContextMenu?: (node: TreeNode, x: number, y: number) => void;
  showSchemaInLabel?: boolean;
}

const iconMap: Record<TreeNodeType, React.ComponentType<{ className?: string }>> = {
  connection: Database,
  database: Database,
  schema: Folder,
  tables: Folder,
  views: Folder,
  table: Table,
  view: Eye,
  'foreign-table': Globe,
  column: Type,
  indexes: Folder,
  index: ListTree,
  constraints: Folder,
  constraint: Link,
  functions: Folder,
  function: FunctionSquare,
  procedure: FunctionSquare,
};

function TreeNodeIcon({ type, isPrimaryKey }: { type: TreeNodeType; isPrimaryKey?: boolean }) {
  if (type === 'column' && isPrimaryKey) {
    return <Key className="w-3.5 h-3.5 text-amber-400" />;
  }

  const Icon = iconMap[type] || Type;
  const colorClass =
    type === 'database'
      ? 'text-blue-400'
      : type === 'schema'
      ? 'text-violet-400'
      : type === 'table'
      ? 'text-emerald-400'
      : type === 'view'
      ? 'text-cyan-400'
      : type === 'foreign-table'
      ? 'text-orange-400'
      : type === 'index'
      ? 'text-blue-400'
      : type === 'constraint'
      ? 'text-amber-400'
      : type === 'function' || type === 'procedure'
      ? 'text-pink-400'
      : 'text-neutral-400';

  return <Icon className={cn('w-3.5 h-3.5', colorClass)} />;
}

interface TreeNodeRowProps {
  node: TreeNode;
  level: number;
  onExpand: (node: TreeNode) => void;
  onSelect: (node: TreeNode) => void;
  onContextMenu: (node: TreeNode, x: number, y: number) => void;
}

function TreeNodeRow({ node, level, onExpand, onSelect, onContextMenu }: TreeNodeRowProps) {
  const hasChildren = node.children && node.children.length > 0;
  const canExpand = hasChildren || ['database', 'schema', 'tables', 'views', 'table', 'foreign-table', 'indexes', 'constraints', 'functions'].includes(node.type);

  const handleClick = () => {
    if (canExpand) {
      onExpand(node);
    }
    onSelect(node);
  };

  const handleContextMenu = (e: React.MouseEvent) => {
    if (node.type === 'table' || node.type === 'view' || node.type === 'foreign-table' || node.type === 'column' || node.type === 'index') {
      e.preventDefault();
      onContextMenu(node, e.clientX, e.clientY);
    }
  };

  return (
    <div
      className={cn(
        'flex items-center gap-1 py-0.5 px-1.5 cursor-pointer rounded mx-0.5',
        'text-xs text-theme-text-secondary hover:bg-theme-bg-hover transition-colors'
      )}
      style={{ paddingLeft: `${level * 10 + 6}px` }}
      onClick={handleClick}
      onContextMenu={handleContextMenu}
    >
      {/* Expand/collapse chevron */}
      <div className="w-3.5 h-3.5 flex items-center justify-center flex-shrink-0">
        {canExpand ? (
          node.isLoading ? (
            <div className="w-2.5 h-2.5 border-[1.5px] border-theme-text-muted border-t-theme-text-secondary rounded-full animate-spin" />
          ) : node.isExpanded ? (
            <ChevronDown className="w-3.5 h-3.5 text-theme-text-tertiary" />
          ) : (
            <ChevronRight className="w-3.5 h-3.5 text-theme-text-tertiary" />
          )
        ) : null}
      </div>

      {/* Icon */}
      <TreeNodeIcon type={node.type} isPrimaryKey={node.metadata?.isPrimaryKey} />

      {/* Label */}
      <span className="truncate flex-1">{node.label}</span>

      {/* Data type badge for columns */}
      {node.type === 'column' && node.metadata?.dataType && (
        <span className="text-[10px] text-theme-text-tertiary font-mono">{node.metadata.dataType}</span>
      )}

      {/* Row count estimate badge for tables/views */}
      {(node.type === 'table' || node.type === 'view' || node.type === 'foreign-table') &&
        node.metadata?.rowCountUnavailable && (
        <span className="text-[10px] text-theme-text-tertiary font-mono italic" title="Row count unavailable (insufficient privileges to analyze)">
          N/A
        </span>
      )}
      {(node.type === 'table' || node.type === 'view' || node.type === 'foreign-table') &&
        !node.metadata?.rowCountUnavailable &&
        node.metadata?.rowCountEstimate != null &&
        formatRowCount(node.metadata.rowCountEstimate) && (
        <span className="text-[10px] text-theme-text-muted font-mono" title={`~${node.metadata.rowCountEstimate.toLocaleString()} rows (estimate)`}>
          ~{formatRowCount(node.metadata.rowCountEstimate)}
        </span>
      )}

      {/* Table size badge */}
      {(node.type === 'table' || node.type === 'foreign-table') &&
        node.metadata?.totalSizeBytes != null &&
        formatBytes(node.metadata.totalSizeBytes) && (
        <span className="text-[10px] text-theme-text-tertiary font-mono" title={`${node.metadata.totalSizeBytes.toLocaleString()} bytes`}>
          {formatBytes(node.metadata.totalSizeBytes)}
        </span>
      )}

      {/* Index type badge */}
      {node.type === 'index' && node.metadata?.indexType && (
        <span className="text-[10px] text-theme-text-tertiary font-mono">
          {node.metadata.indexType}
          {node.metadata.isUnique && !node.metadata.isPrimaryKey && (
            <span className="text-cyan-400 ml-1">UQ</span>
          )}
        </span>
      )}

      {/* Constraint type badge */}
      {node.type === 'constraint' && node.metadata?.constraintType && (
        <span className={cn('text-[10px] font-mono',
          node.metadata.constraintType === 'PRIMARY KEY' ? 'text-amber-400' :
          node.metadata.constraintType === 'FOREIGN KEY' ? 'text-orange-400' :
          node.metadata.constraintType === 'UNIQUE' ? 'text-cyan-400' :
          node.metadata.constraintType === 'CHECK' ? 'text-emerald-400' :
          'text-theme-text-tertiary'
        )}>
          {node.metadata.constraintType === 'PRIMARY KEY' ? 'PK' :
           node.metadata.constraintType === 'FOREIGN KEY' ? 'FK' :
           node.metadata.constraintType === 'UNIQUE' ? 'UQ' :
           node.metadata.constraintType === 'CHECK' ? 'CK' :
           node.metadata.constraintType}
        </span>
      )}

      {/* Function return type and language badge */}
      {(node.type === 'function' || node.type === 'procedure') && node.metadata?.returnType && (
        <span className="text-[10px] text-theme-text-tertiary font-mono truncate max-w-[80px]" title={`→ ${node.metadata.returnType} (${node.metadata.language})`}>
          → {node.metadata.returnType}
        </span>
      )}
    </div>
  );
}

function TreeNodeList({
  nodes,
  level,
  onExpand,
  onSelect,
  onContextMenu,
}: {
  nodes: TreeNode[];
  level: number;
  onExpand: (node: TreeNode) => void;
  onSelect: (node: TreeNode) => void;
  onContextMenu: (node: TreeNode, x: number, y: number) => void;
}) {
  return (
    <>
      {nodes.map((node) => (
        <div key={node.id}>
          <TreeNodeRow node={node} level={level} onExpand={onExpand} onSelect={onSelect} onContextMenu={onContextMenu} />
          {node.isExpanded && node.children && (
            <TreeNodeList
              nodes={node.children}
              level={level + 1}
              onExpand={onExpand}
              onSelect={onSelect}
              onContextMenu={onContextMenu}
            />
          )}
        </div>
      ))}
    </>
  );
}

export function SchemaTree({ nodes, onNodeExpand, onNodeSelect, onNodeContextMenu, showSchemaInLabel: _showSchemaInLabel }: SchemaTreeProps) {
  const handleExpand = useCallback(
    (node: TreeNode) => {
      onNodeExpand?.(node);
    },
    [onNodeExpand]
  );

  const handleSelect = useCallback(
    (node: TreeNode) => {
      onNodeSelect?.(node);
    },
    [onNodeSelect]
  );

  const handleContextMenu = useCallback(
    (node: TreeNode, x: number, y: number) => {
      onNodeContextMenu?.(node, x, y);
    },
    [onNodeContextMenu]
  );

  if (nodes.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center h-32 text-theme-text-tertiary text-sm p-6">
        <p>No tables found</p>
      </div>
    );
  }

  return (
    <div className="py-1">
      <TreeNodeList nodes={nodes} level={0} onExpand={handleExpand} onSelect={handleSelect} onContextMenu={handleContextMenu} />
    </div>
  );
}
