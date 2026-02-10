import { useEffect, useState, useCallback, useRef } from 'react';
import {
  FileText,
  Folder,
  FolderOpen,
  FolderPlus,
  FilePlus,
  ChevronRight,
  ChevronDown,
  MoreHorizontal,
  Trash2,
  Edit3,
  Search,
  FolderInput,
  GripVertical,
} from 'lucide-react';
import { ask } from '@tauri-apps/plugin-dialog';
import { cn } from '@/lib/cn';
import { useSavedQueryStore } from '@/stores/savedQueryStore';
import { useSettingsStore } from '@/stores/settingsStore';
import { useContextMenuPosition } from '@/hooks/useContextMenuPosition';
import * as tauri from '@/lib/tauri';
import type { SavedQuery } from '@/lib/types';

interface SavedQueriesPanelProps {
  onQuerySelect?: (query: SavedQuery) => void;
}

export function SavedQueriesPanel({ onQuerySelect }: SavedQueriesPanelProps) {
  const {
    queries,
    isLoading,
    loadQueries,
    deleteQuery,
    createQuery,
    updateQuery,
    emptyFolders,
    setEmptyFolders,
    addEmptyFolder,
    removeEmptyFolder,
    renameEmptyFolder,
    getAllFolders,
  } = useSavedQueryStore();

  const { settings, updateEmptyFolders } = useSettingsStore();

  const [searchQuery, setSearchQuery] = useState('');
  const [expandedFolders, setExpandedFolders] = useState<Set<string>>(new Set(['']));

  // Context menus
  const [queryContextMenu, setQueryContextMenu] = useState<{
    x: number;
    y: number;
    query: SavedQuery;
  } | null>(null);

  const [folderContextMenu, setFolderContextMenu] = useState<{
    x: number;
    y: number;
    folderName: string;
    hasQueries: boolean;
  } | null>(null);

  const queryMenuPositionRef = useContextMenuPosition(queryContextMenu?.x, queryContextMenu?.y);
  const folderMenuPositionRef = useContextMenuPosition(folderContextMenu?.x, folderContextMenu?.y);

  // Inline folder creation/editing
  const [isCreatingFolder, setIsCreatingFolder] = useState(false);
  const [newFolderName, setNewFolderName] = useState('');
  const [editingFolder, setEditingFolder] = useState<string | null>(null);
  const [editingFolderName, setEditingFolderName] = useState('');
  const newFolderInputRef = useRef<HTMLInputElement>(null);
  const editFolderInputRef = useRef<HTMLInputElement>(null);

  // Mouse-based drag and drop (more reliable in Tauri than HTML5 drag API)
  const [draggingQueryId, setDraggingQueryId] = useState<string | null>(null);
  const [dragOverFolder, setDragOverFolder] = useState<string | null>(null);
  const [dragPosition, setDragPosition] = useState<{ x: number; y: number } | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const folderHeadersRef = useRef<Map<string, HTMLDivElement>>(new Map());

  // Load queries and empty folders on mount
  useEffect(() => {
    loadQueries();
  }, [loadQueries]);

  // Sync emptyFolders from settings on load
  useEffect(() => {
    if (settings.emptyFolders) {
      setEmptyFolders(settings.emptyFolders);
    }
  }, [settings.emptyFolders, setEmptyFolders]);

  // Persist emptyFolders when they change
  useEffect(() => {
    // Only persist if different from settings
    const settingsFolders = settings.emptyFolders ?? [];
    if (JSON.stringify(emptyFolders) !== JSON.stringify(settingsFolders)) {
      updateEmptyFolders(emptyFolders);
      tauri.saveSettings({ ...settings, emptyFolders }).catch(console.error);
    }
  }, [emptyFolders, settings, updateEmptyFolders]);

  // Focus new folder input when creating
  useEffect(() => {
    if (isCreatingFolder && newFolderInputRef.current) {
      newFolderInputRef.current.focus();
    }
  }, [isCreatingFolder]);

  // Focus edit folder input when editing
  useEffect(() => {
    if (editingFolder && editFolderInputRef.current) {
      editFolderInputRef.current.focus();
      editFolderInputRef.current.select();
    }
  }, [editingFolder]);

  // Organize queries into folders, including empty folders
  const organizedQueries = useCallback(() => {
    const folders = new Map<string, SavedQuery[]>();

    const filteredQueries = searchQuery
      ? queries.filter(
          (q) =>
            q.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
            q.sql.toLowerCase().includes(searchQuery.toLowerCase())
        )
      : queries;

    // Initialize with empty folders (only when not searching)
    if (!searchQuery) {
      emptyFolders.forEach((folder) => {
        folders.set(folder, []);
      });
    }

    // Add queries to their folders
    filteredQueries.forEach((query) => {
      const folderName = query.folder || '';
      if (!folders.has(folderName)) {
        folders.set(folderName, []);
      }
      folders.get(folderName)!.push(query);
    });

    return folders;
  }, [queries, searchQuery, emptyFolders]);

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

  // Query context menu
  const handleQueryContextMenu = useCallback((e: React.MouseEvent, query: SavedQuery) => {
    e.preventDefault();
    setFolderContextMenu(null);
    setQueryContextMenu({ x: e.clientX, y: e.clientY, query });
  }, []);

  // Folder context menu
  const handleFolderContextMenu = useCallback(
    (e: React.MouseEvent, folderName: string, queryCount: number) => {
      e.preventDefault();
      e.stopPropagation();
      setQueryContextMenu(null);
      setFolderContextMenu({
        x: e.clientX,
        y: e.clientY,
        folderName,
        hasQueries: queryCount > 0,
      });
    },
    []
  );

  const handleDeleteQuery = useCallback(
    async (query: SavedQuery) => {
      const queryId = query.id;
      const queryName = query.name;
      setQueryContextMenu(null);

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

  const handleDeleteFolder = useCallback(
    async (folderName: string) => {
      setFolderContextMenu(null);

      const confirmed = await ask(`Delete folder "${folderName}"?`, {
        title: 'Delete Folder',
        kind: 'warning',
      });

      if (confirmed) {
        removeEmptyFolder(folderName);
      }
    },
    [removeEmptyFolder]
  );

  const handleRenameFolder = useCallback((folderName: string) => {
    setFolderContextMenu(null);
    setEditingFolder(folderName);
    setEditingFolderName(folderName);
  }, []);

  const confirmRenameFolder = useCallback(() => {
    if (editingFolder && editingFolderName.trim()) {
      renameEmptyFolder(editingFolder, editingFolderName.trim());
    }
    setEditingFolder(null);
    setEditingFolderName('');
  }, [editingFolder, editingFolderName, renameEmptyFolder]);

  const cancelRenameFolder = useCallback(() => {
    setEditingFolder(null);
    setEditingFolderName('');
  }, []);

  // New folder creation
  const handleNewFolder = useCallback(() => {
    setIsCreatingFolder(true);
    setNewFolderName('');
  }, []);

  const confirmNewFolder = useCallback(() => {
    const trimmed = newFolderName.trim();
    if (trimmed) {
      addEmptyFolder(trimmed);
      setExpandedFolders((prev) => new Set([...prev, trimmed]));
    }
    setIsCreatingFolder(false);
    setNewFolderName('');
  }, [newFolderName, addEmptyFolder]);

  const cancelNewFolder = useCallback(() => {
    setIsCreatingFolder(false);
    setNewFolderName('');
  }, []);

  // New query creation
  const handleNewQuery = useCallback(async () => {
    try {
      const newQuery = await createQuery({
        name: 'Untitled Query',
        sql: '',
        folder: undefined,
      });
      onQuerySelect?.(newQuery);
    } catch (err) {
      console.error('Failed to create query:', err);
    }
  }, [createQuery, onQuerySelect]);

  // Move query to folder
  const handleMoveToFolder = useCallback(
    async (queryId: string, targetFolder: string) => {
      setQueryContextMenu(null);
      try {
        await updateQuery({ id: queryId, folder: targetFolder });
        // If target was an empty folder, remove it from emptyFolders
        if (targetFolder && emptyFolders.includes(targetFolder)) {
          removeEmptyFolder(targetFolder);
        }
      } catch (err) {
        console.error('Failed to move query:', err);
      }
    },
    [updateQuery, emptyFolders, removeEmptyFolder]
  );

  // Mouse-based drag start
  const handleDragMouseDown = useCallback((e: React.MouseEvent, queryId: string) => {
    // Only start drag on left mouse button
    if (e.button !== 0) return;
    e.preventDefault();
    e.stopPropagation();
    setDraggingQueryId(queryId);
    setDragPosition({ x: e.clientX, y: e.clientY });
  }, []);

  // Mouse-based drag tracking (document level)
  useEffect(() => {
    if (!draggingQueryId) return;

    const handleMouseMove = (e: MouseEvent) => {
      setDragPosition({ x: e.clientX, y: e.clientY });

      // Find which folder header the mouse is over
      let foundFolder: string | null = null;
      let closestDistance = Infinity;

      folderHeadersRef.current.forEach((element, folderName) => {
        if (element) {
          const rect = element.getBoundingClientRect();
          // Check if cursor is within horizontal bounds and near vertical bounds
          if (e.clientX >= rect.left && e.clientX <= rect.right) {
            // Allow some vertical tolerance (within 40px of the folder header)
            const verticalDistance = e.clientY < rect.top
              ? rect.top - e.clientY
              : e.clientY > rect.bottom
                ? e.clientY - rect.bottom
                : 0;

            if (verticalDistance <= 40 && e.clientY >= rect.top - 20 && e.clientY <= rect.bottom + 40) {
              // Prefer exact hit over near hit
              const distance = verticalDistance === 0 ? 0 : verticalDistance;
              if (distance < closestDistance) {
                closestDistance = distance;
                foundFolder = folderName;
              }
            }
          }
        }
      });

      setDragOverFolder(foundFolder);
    };

    const handleMouseUp = async () => {
      if (draggingQueryId && dragOverFolder !== null) {
        const query = queries.find((q) => q.id === draggingQueryId);
        const sourceFolder = query?.folder || '';

        // Only update if moving to different folder
        if (sourceFolder !== dragOverFolder) {
          try {
            await updateQuery({
              id: draggingQueryId,
              folder: dragOverFolder,
            });
            // If target was an empty folder, remove it from emptyFolders
            if (dragOverFolder && emptyFolders.includes(dragOverFolder)) {
              removeEmptyFolder(dragOverFolder);
            }
          } catch (err) {
            console.error('Failed to move query:', err);
          }
        }
      }

      setDraggingQueryId(null);
      setDragOverFolder(null);
      setDragPosition(null);
    };

    document.addEventListener('mousemove', handleMouseMove);
    document.addEventListener('mouseup', handleMouseUp);

    return () => {
      document.removeEventListener('mousemove', handleMouseMove);
      document.removeEventListener('mouseup', handleMouseUp);
    };
  }, [draggingQueryId, dragOverFolder, queries, updateQuery, emptyFolders, removeEmptyFolder]);

  // Close context menus on outside click
  useEffect(() => {
    if (!queryContextMenu && !folderContextMenu) return;

    const handleClickOutside = (e: MouseEvent) => {
      const target = e.target as HTMLElement;
      if (target.closest('[data-context-menu]')) return;
      setQueryContextMenu(null);
      setFolderContextMenu(null);
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [queryContextMenu, folderContextMenu]);

  // Store folder header ref (only the clickable header, not the whole container)
  const setFolderHeaderRef = useCallback((folderName: string, element: HTMLDivElement | null) => {
    if (element) {
      folderHeadersRef.current.set(folderName, element);
    } else {
      folderHeadersRef.current.delete(folderName);
    }
  }, []);

  const folders = organizedQueries();
  const sortedFolderNames = Array.from(folders.keys()).sort((a, b) => {
    if (a === '') return -1;
    if (b === '') return 1;
    return a.localeCompare(b);
  });

  const allFolders = getAllFolders();

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-32 text-theme-text-tertiary text-sm">
        Loading saved queries...
      </div>
    );
  }

  return (
    <div className="flex flex-col h-full" ref={containerRef}>
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

      {/* Action bar */}
      <div className="px-2 pb-1.5 flex gap-1">
        <button
          onClick={handleNewFolder}
          className={cn(
            'flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px]',
            'text-theme-text-secondary hover:bg-theme-bg-hover transition-colors',
            'border border-transparent hover:border-theme-border-secondary'
          )}
          title="New Folder"
        >
          <FolderPlus className="w-3 h-3" />
          <span>Folder</span>
        </button>
        <button
          onClick={handleNewQuery}
          className={cn(
            'flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px]',
            'text-theme-text-secondary hover:bg-theme-bg-hover transition-colors',
            'border border-transparent hover:border-theme-border-secondary'
          )}
          title="New Query"
        >
          <FilePlus className="w-3 h-3" />
          <span>Query</span>
        </button>
      </div>

      {/* Query list */}
      <div className="flex-1 overflow-y-auto">
        {queries.length === 0 && emptyFolders.length === 0 && !isCreatingFolder ? (
          <div className="flex flex-col items-center justify-center h-full text-theme-text-tertiary text-xs p-4">
            <FileText className="w-8 h-8 mb-2 text-theme-text-muted" />
            <p className="font-medium text-theme-text-secondary">No saved queries</p>
            <p className="text-[10px] mt-0.5">Save a query with Cmd+S</p>
          </div>
        ) : (
          <div className="py-0.5">
            {/* New folder input (inline creation) */}
            {isCreatingFolder && (
              <div className="flex items-center gap-1 py-0.5 px-1.5 mx-0.5">
                <Folder className="w-3.5 h-3.5 text-amber-500 flex-shrink-0" />
                <input
                  ref={newFolderInputRef}
                  type="text"
                  value={newFolderName}
                  onChange={(e) => setNewFolderName(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') confirmNewFolder();
                    if (e.key === 'Escape') cancelNewFolder();
                  }}
                  onBlur={confirmNewFolder}
                  placeholder="Folder name..."
                  className={cn(
                    'flex-1 px-1 py-0.5 rounded text-xs',
                    'bg-theme-bg-elevated border border-theme-border-secondary',
                    'text-theme-text-primary placeholder-theme-text-muted',
                    'focus:outline-none'
                  )}
                />
              </div>
            )}

            {sortedFolderNames.map((folderName) => {
              const folderQueries = folders.get(folderName) || [];
              const isExpanded = expandedFolders.has(folderName);
              const isRootFolder = folderName === '';
              const isDragOver = draggingQueryId !== null && dragOverFolder === folderName;
              const isEditing = editingFolder === folderName;
              const isEmpty = folderQueries.length === 0;

              return (
                <div
                  key={folderName || '__root__'}
                  className="transition-colors"
                >
                  {/* Folder header (not for root) */}
                  {!isRootFolder && (
                    <div
                      ref={(el) => setFolderHeaderRef(folderName, el)}
                      className={cn(
                        'flex items-center gap-1 py-0.5 px-1.5 cursor-pointer rounded mx-0.5',
                        'text-xs text-theme-text-secondary hover:bg-theme-bg-hover transition-colors',
                        isDragOver && 'bg-blue-500/30 border border-blue-500'
                      )}
                      onClick={() => !isEditing && toggleFolder(folderName)}
                      onContextMenu={(e) => handleFolderContextMenu(e, folderName, folderQueries.length)}
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
                      {isEditing ? (
                        <input
                          ref={editFolderInputRef}
                          type="text"
                          value={editingFolderName}
                          onChange={(e) => setEditingFolderName(e.target.value)}
                          onKeyDown={(e) => {
                            e.stopPropagation();
                            if (e.key === 'Enter') confirmRenameFolder();
                            if (e.key === 'Escape') cancelRenameFolder();
                          }}
                          onBlur={confirmRenameFolder}
                          onClick={(e) => e.stopPropagation()}
                          className={cn(
                            'flex-1 px-1 py-0 rounded text-xs',
                            'bg-theme-bg-elevated border border-theme-border-secondary',
                            'text-theme-text-primary',
                            'focus:outline-none'
                          )}
                        />
                      ) : (
                        <span className="truncate flex-1">{folderName}</span>
                      )}
                      {!isEditing && (
                        <span className={cn('text-[10px]', isEmpty ? 'text-theme-text-muted' : 'text-theme-text-tertiary')}>
                          {isEmpty ? 'empty' : folderQueries.length}
                        </span>
                      )}
                    </div>
                  )}

                  {/* Root folder drop zone header */}
                  {isRootFolder && (sortedFolderNames.length > 1 || folderQueries.length > 0) && (
                    <div
                      ref={(el) => setFolderHeaderRef('', el)}
                      className={cn(
                        'flex items-center gap-1 py-1 px-1.5 mx-0.5 rounded',
                        'text-[10px] text-theme-text-muted uppercase tracking-wide',
                        isDragOver && 'bg-blue-500/30 border border-blue-500'
                      )}
                    >
                      Ungrouped
                    </div>
                  )}

                  {/* Queries in folder */}
                  {(isRootFolder || isExpanded) &&
                    folderQueries.map((query) => {
                      const isBeingDragged = draggingQueryId === query.id;

                      return (
                        <div
                          key={query.id}
                          className={cn(
                            'flex items-center gap-1 py-0.5 px-1.5 cursor-pointer rounded mx-0.5',
                            'text-xs text-theme-text-secondary hover:bg-theme-bg-hover transition-colors',
                            'group',
                            isBeingDragged && 'opacity-50 bg-theme-bg-active'
                          )}
                          style={{ paddingLeft: isRootFolder ? '6px' : '24px' }}
                          onClick={() => !isBeingDragged && onQuerySelect?.(query)}
                          onContextMenu={(e) => handleQueryContextMenu(e, query)}
                        >
                          {/* Drag handle */}
                          <div
                            className="cursor-grab active:cursor-grabbing p-0.5 -ml-1 opacity-0 group-hover:opacity-60 hover:!opacity-100 transition-opacity"
                            onMouseDown={(e) => handleDragMouseDown(e, query.id)}
                          >
                            <GripVertical className="w-3 h-3 text-theme-text-tertiary" />
                          </div>
                          <FileText className="w-3.5 h-3.5 text-blue-500 flex-shrink-0" />
                          <span className="truncate flex-1">{query.name}</span>
                          <button
                            className="opacity-0 group-hover:opacity-100 p-0.5 rounded hover:bg-theme-bg-hover transition-opacity"
                            onClick={(e) => {
                              e.stopPropagation();
                              handleQueryContextMenu(e, query);
                            }}
                          >
                            <MoreHorizontal className="w-3 h-3 text-theme-text-tertiary" />
                          </button>
                        </div>
                      );
                    })}

                  {/* Empty folder message */}
                  {!isRootFolder && isExpanded && isEmpty && (
                    <div
                      className={cn(
                        'text-[10px] text-theme-text-muted py-1 px-6 italic',
                        isDragOver && 'text-blue-400'
                      )}
                    >
                      {isDragOver ? 'Drop here' : 'Drop queries here'}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* Drag indicator overlay */}
      {draggingQueryId && dragPosition && (
        <div className="fixed inset-0 z-40 pointer-events-none">
          {/* Floating indicator near cursor */}
          <div
            className={cn(
              'absolute px-2 py-1 rounded text-xs shadow-lg whitespace-nowrap',
              'transform -translate-x-1/2 -translate-y-full',
              dragOverFolder !== null
                ? 'bg-blue-600 text-white border border-blue-500'
                : 'bg-theme-bg-elevated text-theme-text-secondary border border-theme-border-secondary'
            )}
            style={{
              left: dragPosition.x,
              top: dragPosition.y - 8,
            }}
          >
            {dragOverFolder !== null
              ? dragOverFolder === ''
                ? '→ Ungrouped'
                : `→ ${dragOverFolder}`
              : 'Drag to folder...'}
          </div>
        </div>
      )}

      {/* Query context menu */}
      {queryContextMenu && (
        <div
          ref={queryMenuPositionRef}
          data-context-menu
          className="fixed z-50 min-w-[140px] py-0.5 bg-theme-bg-elevated border border-theme-border-secondary rounded-md shadow-xl"
          style={{ left: queryContextMenu.x, top: queryContextMenu.y }}
        >
          <button
            className="w-full flex items-center gap-1.5 px-2 py-1 text-xs text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
            onClick={() => {
              onQuerySelect?.(queryContextMenu.query);
              setQueryContextMenu(null);
            }}
          >
            <Edit3 className="w-3.5 h-3.5" />
            Open
          </button>

          {/* Move to folder submenu */}
          <div className="relative group/move">
            <button className="w-full flex items-center gap-1.5 px-2 py-1 text-xs text-theme-text-secondary hover:bg-theme-bg-hover transition-colors">
              <FolderInput className="w-3.5 h-3.5" />
              Move to...
              <ChevronRight className="w-3 h-3 ml-auto" />
            </button>
            <div className="absolute left-full top-0 ml-0.5 hidden group-hover/move:block min-w-[120px] py-0.5 bg-theme-bg-elevated border border-theme-border-secondary rounded-md shadow-xl">
              <button
                className={cn(
                  'w-full flex items-center gap-1.5 px-2 py-1 text-xs hover:bg-theme-bg-hover transition-colors',
                  !queryContextMenu.query.folder ? 'text-theme-text-muted' : 'text-theme-text-secondary'
                )}
                onClick={() => handleMoveToFolder(queryContextMenu.query.id, '')}
                disabled={!queryContextMenu.query.folder}
              >
                No folder
              </button>
              {allFolders.map((folder) => (
                <button
                  key={folder}
                  className={cn(
                    'w-full flex items-center gap-1.5 px-2 py-1 text-xs hover:bg-theme-bg-hover transition-colors',
                    queryContextMenu.query.folder === folder ? 'text-theme-text-muted' : 'text-theme-text-secondary'
                  )}
                  onClick={() => handleMoveToFolder(queryContextMenu.query.id, folder)}
                  disabled={queryContextMenu.query.folder === folder}
                >
                  <Folder className="w-3 h-3 text-amber-500" />
                  {folder}
                </button>
              ))}
            </div>
          </div>

          <div className="border-t border-theme-border-primary my-0.5" />
          <button
            className="w-full flex items-center gap-1.5 px-2 py-1 text-xs text-red-500 hover:bg-theme-bg-hover transition-colors"
            onClick={() => handleDeleteQuery(queryContextMenu.query)}
          >
            <Trash2 className="w-3.5 h-3.5" />
            Delete
          </button>
        </div>
      )}

      {/* Folder context menu */}
      {folderContextMenu && (
        <div
          ref={folderMenuPositionRef}
          data-context-menu
          className="fixed z-50 min-w-[120px] py-0.5 bg-theme-bg-elevated border border-theme-border-secondary rounded-md shadow-xl"
          style={{ left: folderContextMenu.x, top: folderContextMenu.y }}
        >
          <button
            className="w-full flex items-center gap-1.5 px-2 py-1 text-xs text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
            onClick={() => handleRenameFolder(folderContextMenu.folderName)}
            disabled={folderContextMenu.hasQueries}
          >
            <Edit3 className="w-3.5 h-3.5" />
            Rename
          </button>
          <button
            className={cn(
              'w-full flex items-center gap-1.5 px-2 py-1 text-xs hover:bg-theme-bg-hover transition-colors',
              folderContextMenu.hasQueries ? 'text-theme-text-muted cursor-not-allowed' : 'text-red-500'
            )}
            onClick={() => !folderContextMenu.hasQueries && handleDeleteFolder(folderContextMenu.folderName)}
            disabled={folderContextMenu.hasQueries}
            title={folderContextMenu.hasQueries ? 'Move all queries first' : undefined}
          >
            <Trash2 className="w-3.5 h-3.5" />
            Delete
          </button>
        </div>
      )}
    </div>
  );
}
