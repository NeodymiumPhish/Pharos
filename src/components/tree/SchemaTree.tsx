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
} from 'lucide-react';
import { cn } from '@/lib/cn';
import type { TreeNode, TreeNodeType } from '@/lib/types';

interface SchemaTreeProps {
  nodes: TreeNode[];
  onNodeExpand?: (node: TreeNode) => void;
  onNodeSelect?: (node: TreeNode) => void;
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
  column: Type,
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
      : 'text-neutral-400';

  return <Icon className={cn('w-3.5 h-3.5', colorClass)} />;
}

interface TreeNodeRowProps {
  node: TreeNode;
  level: number;
  onExpand: (node: TreeNode) => void;
  onSelect: (node: TreeNode) => void;
}

function TreeNodeRow({ node, level, onExpand, onSelect }: TreeNodeRowProps) {
  const hasChildren = node.children && node.children.length > 0;
  const canExpand = hasChildren || ['database', 'schema', 'tables', 'views', 'table'].includes(node.type);

  const handleClick = () => {
    if (canExpand) {
      onExpand(node);
    }
    onSelect(node);
  };

  return (
    <div
      className={cn(
        'flex items-center gap-1 py-0.5 px-1.5 cursor-pointer rounded mx-0.5',
        'text-xs text-theme-text-secondary hover:bg-theme-bg-hover transition-colors'
      )}
      style={{ paddingLeft: `${level * 10 + 6}px` }}
      onClick={handleClick}
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
    </div>
  );
}

function TreeNodeList({
  nodes,
  level,
  onExpand,
  onSelect,
}: {
  nodes: TreeNode[];
  level: number;
  onExpand: (node: TreeNode) => void;
  onSelect: (node: TreeNode) => void;
}) {
  return (
    <>
      {nodes.map((node) => (
        <div key={node.id}>
          <TreeNodeRow node={node} level={level} onExpand={onExpand} onSelect={onSelect} />
          {node.isExpanded && node.children && (
            <TreeNodeList
              nodes={node.children}
              level={level + 1}
              onExpand={onExpand}
              onSelect={onSelect}
            />
          )}
        </div>
      ))}
    </>
  );
}

export function SchemaTree({ nodes, onNodeExpand, onNodeSelect, showSchemaInLabel: _showSchemaInLabel }: SchemaTreeProps) {
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

  if (nodes.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center h-32 text-theme-text-tertiary text-sm p-6">
        <p>No tables found</p>
      </div>
    );
  }

  return (
    <div className="py-1">
      <TreeNodeList nodes={nodes} level={0} onExpand={handleExpand} onSelect={handleSelect} />
    </div>
  );
}
