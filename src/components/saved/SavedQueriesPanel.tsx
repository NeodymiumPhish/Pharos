import { useEffect, useState, useCallback } from 'react';
import {
  FileText,
  Folder,
  FolderOpen,
  ChevronRight,
  ChevronDown,
  MoreHorizontal,
  Trash2,
  Edit3,
  Search,
} from 'lucide-react';
import { ask } from '@tauri-apps/plugin-dialog';
import { cn } from '@/lib/cn';
import { useSavedQueryStore } from '@/stores/savedQueryStore';
import type { SavedQuery } from '@/lib/types';

interface SavedQueriesPanelProps {
  onQuerySelect?: (query: SavedQuery) => void;
}

export function SavedQueriesPanel({ onQuerySelect }: SavedQueriesPanelProps) {
  const { queries, isLoading, loadQueries, deleteQuery } = useSavedQueryStore();
  const [searchQuery, setSearchQuery] = useState('');
  const [expandedFolders, setExpandedFolders] = useState<Set<string>>(new Set(['']));
  const [contextMenu, setContextMenu] = useState<{
    x: number;
    y: number;
    query: SavedQuery;
  } | null>(null);

  useEffect(() => {
    loadQueries();
  }, [loadQueries]);

  // Organize queries into folders
  const organizedQueries = useCallback(() => {
    const folders = new Map<string, SavedQuery[]>();

    const filteredQueries = searchQuery
      ? queries.filter(
          (q) =>
            q.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
            q.sql.toLowerCase().includes(searchQuery.toLowerCase())
        )
      : queries;

    filteredQueries.forEach((query) => {
      const folderName = query.folder || '';
      if (!folders.has(folderName)) {
        folders.set(folderName, []);
      }
      folders.get(folderName)!.push(query);
    });

    return folders;
  }, [queries, searchQuery]);

  const toggleFolder = useCallback((folderName: string) => {
    setExpandedFolders((prev) => {
      const next = new Set(prev);
      if (next.has(folderName)) {
        next.delete(folderName);
      } else {
        next.add(folderName);
      }
      return next;
    });
  }, []);

  const handleContextMenu = useCallback((e: React.MouseEvent, query: SavedQuery) => {
    e.preventDefault();
    setContextMenu({ x: e.clientX, y: e.clientY, query });
  }, []);

  const handleDelete = useCallback(
    async (query: SavedQuery) => {
      const queryId = query.id;
      const queryName = query.name;
      setContextMenu(null);

      const confirmed = await ask(`Delete "${queryName}"?`, {
        title: 'Delete Query',
        kind: 'warning',
      });

      if (confirmed) {
        try {
          await deleteQuery(queryId);
        } catch (err) {
          console.error('Failed to delete query:', err);
        }
      }
    },
    [deleteQuery]
  );

  useEffect(() => {
    if (!contextMenu) return;

    const handleClickOutside = (e: MouseEvent) => {
      // Don't close if clicking inside the context menu
      const target = e.target as HTMLElement;
      if (target.closest('[data-context-menu]')) return;
      setContextMenu(null);
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [contextMenu]);

  const folders = organizedQueries();
  const sortedFolderNames = Array.from(folders.keys()).sort((a, b) => {
    if (a === '') return -1;
    if (b === '') return 1;
    return a.localeCompare(b);
  });

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-32 text-theme-text-tertiary text-sm">
        Loading saved queries...
      </div>
    );
  }

  return (
    <div className="flex flex-col h-full">
      {/* Search */}
      <div className="px-2 py-1.5">
        <div className="relative">
          <Search className="absolute left-2 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-theme-text-tertiary" />
          <input
            type="text"
            placeholder="Search queries..."
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

      {/* Query list */}
      <div className="flex-1 overflow-y-auto">
        {queries.length === 0 ? (
          <div className="flex flex-col items-center justify-center h-full text-theme-text-tertiary text-xs p-4">
            <FileText className="w-8 h-8 mb-2 text-theme-text-muted" />
            <p className="font-medium text-theme-text-secondary">No saved queries</p>
            <p className="text-[10px] mt-0.5">Save a query with Cmd+S</p>
          </div>
        ) : (
          <div className="py-0.5">
            {sortedFolderNames.map((folderName) => {
              const folderQueries = folders.get(folderName) || [];
              const isExpanded = expandedFolders.has(folderName);
              const isRootFolder = folderName === '';

              return (
                <div key={folderName || '__root__'}>
                  {!isRootFolder && (
                    <div
                      className={cn(
                        'flex items-center gap-1 py-0.5 px-1.5 cursor-pointer rounded mx-0.5',
                        'text-xs text-theme-text-secondary hover:bg-theme-bg-hover transition-colors'
                      )}
                      onClick={() => toggleFolder(folderName)}
                    >
                      <div className="w-3.5 h-3.5 flex items-center justify-center flex-shrink-0">
                        {isExpanded ? (
                          <ChevronDown className="w-3.5 h-3.5 text-theme-text-tertiary" />
                        ) : (
                          <ChevronRight className="w-3.5 h-3.5 text-theme-text-tertiary" />
                        )}
                      </div>
                      {isExpanded ? (
                        <FolderOpen className="w-3.5 h-3.5 text-amber-500" />
                      ) : (
                        <Folder className="w-3.5 h-3.5 text-amber-500" />
                      )}
                      <span className="truncate flex-1">{folderName}</span>
                      <span className="text-[10px] text-theme-text-tertiary">{folderQueries.length}</span>
                    </div>
                  )}

                  {(isRootFolder || isExpanded) &&
                    folderQueries.map((query) => (
                      <div
                        key={query.id}
                        className={cn(
                          'flex items-center gap-1 py-0.5 px-1.5 cursor-pointer rounded mx-0.5',
                          'text-xs text-theme-text-secondary hover:bg-theme-bg-hover transition-colors',
                          'group'
                        )}
                        style={{ paddingLeft: isRootFolder ? '6px' : '24px' }}
                        onClick={() => onQuerySelect?.(query)}
                        onContextMenu={(e) => handleContextMenu(e, query)}
                      >
                        <FileText className="w-3.5 h-3.5 text-blue-500 flex-shrink-0" />
                        <span className="truncate flex-1">{query.name}</span>
                        <button
                          className="opacity-0 group-hover:opacity-100 p-0.5 rounded hover:bg-theme-bg-hover transition-opacity"
                          onClick={(e) => {
                            e.stopPropagation();
                            handleContextMenu(e, query);
                          }}
                        >
                          <MoreHorizontal className="w-3 h-3 text-theme-text-tertiary" />
                        </button>
                      </div>
                    ))}
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* Context menu */}
      {contextMenu && (
        <div
          data-context-menu
          className="fixed z-50 min-w-[120px] py-0.5 bg-theme-bg-elevated border border-theme-border-secondary rounded-md shadow-xl"
          style={{ left: contextMenu.x, top: contextMenu.y }}
        >
          <button
            className="w-full flex items-center gap-1.5 px-2 py-1 text-xs text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
            onClick={() => {
              onQuerySelect?.(contextMenu.query);
              setContextMenu(null);
            }}
          >
            <Edit3 className="w-3.5 h-3.5" />
            Open
          </button>
          <button
            className="w-full flex items-center gap-1.5 px-2 py-1 text-xs text-red-500 hover:bg-theme-bg-hover transition-colors"
            onClick={() => handleDelete(contextMenu.query)}
          >
            <Trash2 className="w-3.5 h-3.5" />
            Delete
          </button>
        </div>
      )}
    </div>
  );
}
