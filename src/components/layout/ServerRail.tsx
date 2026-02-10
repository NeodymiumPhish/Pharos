import { useState, useCallback, useEffect, useRef } from 'react';
import { Plus, Database, Power, PowerOff, RefreshCw, Trash2, Pencil, Copy } from 'lucide-react';
import { ask } from '@tauri-apps/plugin-dialog';
import { cn } from '@/lib/cn';
import { useConnectionStore } from '@/stores/connectionStore';
import * as tauri from '@/lib/tauri';
import type { Connection } from '@/lib/types';

interface ServerRailProps {
  onAddConnection: () => void;
  onEditConnection: (connection: Connection) => void;
  onSchemaRefresh?: (connectionId: string) => void;
}

interface ConnectionIconProps {
  connection: Connection;
  isActive: boolean;
  isDragging: boolean;
  isDragOver: boolean;
  onConnect: (connection: Connection) => void;
  onDisconnect: (connection: Connection) => void;
  onEdit: (connection: Connection) => void;
  onRefresh: (connection: Connection) => void;
  onDelete: (connection: Connection) => void;
  onDuplicate: (connection: Connection) => void;
  onDragStart: (e: React.MouseEvent, connectionId: string) => void;
  setRef: (connectionId: string, element: HTMLDivElement | null) => void;
}

function ConnectionIcon({
  connection,
  isActive,
  isDragging,
  isDragOver,
  onConnect,
  onDisconnect,
  onEdit,
  onRefresh,
  onDelete,
  onDuplicate,
  onDragStart,
  setRef,
}: ConnectionIconProps) {
  const setActiveConnection = useConnectionStore((state) => state.setActiveConnection);
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number } | null>(null);
  const menuRef = useRef<HTMLDivElement>(null);

  const handleClick = async () => {
    setActiveConnection(connection.config.id);

    // Auto-connect if not connected
    if (connection.status === 'disconnected' || connection.status === 'error') {
      onConnect(connection);
    }
  };

  const handleContextMenu = (e: React.MouseEvent) => {
    e.preventDefault();
    setContextMenu({ x: e.clientX, y: e.clientY });
  };

  useEffect(() => {
    if (!contextMenu) return;

    const handleClickOutside = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setContextMenu(null);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [contextMenu]);

  const statusColors = {
    connected: 'bg-emerald-500',
    disconnected: 'bg-gray-400',
    connecting: 'bg-amber-500 animate-pulse',
    error: 'bg-red-500',
  };

  return (
    <>
      <div
        ref={(el) => setRef(connection.config.id, el)}
        className={cn(
          'relative transition-all duration-150',
          isDragging && 'opacity-40 scale-95',
          isDragOver && 'pt-3'
        )}
      >
        {/* Drop indicator line */}
        {isDragOver && (
          <div className="absolute top-0 left-1/2 -translate-x-1/2 w-7 h-1 bg-blue-500 rounded-full" />
        )}
        <button
          onClick={handleClick}
          onContextMenu={handleContextMenu}
          onMouseDown={(e) => {
            // Only start drag on left mouse button
            if (e.button === 0) {
              onDragStart(e, connection.config.id);
            }
          }}
          className={cn(
            'relative w-9 h-11 rounded-lg flex flex-col items-center justify-center gap-0.5 transition-all duration-200',
            'hover:bg-theme-bg-hover cursor-grab active:cursor-grabbing',
            isActive ? 'bg-theme-bg-active ring-1 ring-theme-border-secondary' : 'bg-transparent'
          )}
        >
          <div className="relative">
            <Database className={cn('w-4 h-4', isActive ? 'text-theme-text-primary' : 'text-theme-text-secondary')} />
            <div
              className={cn(
                'absolute -bottom-0.5 -right-0.5 w-2 h-2 rounded-full ring-[1.5px] ring-theme-bg-elevated',
                statusColors[connection.status]
              )}
            />
          </div>
          {connection.config.color && (
            <div
              className="absolute bottom-0 left-1/2 -translate-x-1/2 w-5 h-0.5 rounded-full"
              style={{ backgroundColor: connection.config.color }}
            />
          )}
          <span
            className={cn(
              'text-[8px] font-medium truncate max-w-[36px] text-center leading-tight',
              isActive ? 'text-theme-text-primary' : 'text-theme-text-tertiary'
            )}
          >
            {connection.config.name}
          </span>
        </button>
      </div>

      {/* Context Menu */}
      {contextMenu && (
        <div
          ref={menuRef}
          className="fixed z-50 min-w-[160px] py-1 bg-theme-bg-elevated border border-theme-border-secondary rounded-lg shadow-xl"
          style={{ left: contextMenu.x, top: contextMenu.y }}
        >
          {connection.status === 'connected' ? (
            <button
              className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
              onClick={() => {
                onDisconnect(connection);
                setContextMenu(null);
              }}
            >
              <PowerOff className="w-4 h-4" />
              Disconnect
            </button>
          ) : (
            <button
              className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
              onClick={() => {
                onConnect(connection);
                setContextMenu(null);
              }}
              disabled={connection.status === 'connecting'}
            >
              <Power className="w-4 h-4" />
              Connect
            </button>
          )}
          <button
            className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
            onClick={() => {
              onRefresh(connection);
              setContextMenu(null);
            }}
            disabled={connection.status !== 'connected'}
          >
            <RefreshCw className="w-4 h-4" />
            Refresh Schema
          </button>
          <button
            className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
            onClick={() => {
              onEdit(connection);
              setContextMenu(null);
            }}
          >
            <Pencil className="w-4 h-4" />
            Edit Connection
          </button>
          <button
            className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
            onClick={() => {
              onDuplicate(connection);
              setContextMenu(null);
            }}
          >
            <Copy className="w-4 h-4" />
            Duplicate Connection
          </button>
          <div className="my-1 border-t border-theme-border-primary" />
          <button
            className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-red-400 hover:bg-theme-bg-hover transition-colors"
            onClick={() => {
              // Capture connection before closing menu
              const conn = connection;
              setContextMenu(null);
              // Delay to allow menu to close before confirm dialog
              setTimeout(() => onDelete(conn), 10);
            }}
          >
            <Trash2 className="w-4 h-4" />
            Delete Connection
          </button>
        </div>
      )}
    </>
  );
}

export function ServerRail({ onAddConnection, onEditConnection, onSchemaRefresh }: ServerRailProps) {
  const connections = useConnectionStore((state) => state.connections);
  const connectionOrder = useConnectionStore((state) => state.connectionOrder);
  const activeConnectionId = useConnectionStore((state) => state.activeConnectionId);
  const updateConnectionStatus = useConnectionStore((state) => state.updateConnectionStatus);
  const addConnection = useConnectionStore((state) => state.addConnection);
  const removeConnection = useConnectionStore((state) => state.removeConnection);
  const reorderConnections = useConnectionStore((state) => state.reorderConnections);

  // Derive ordered connections from state
  const orderedConnections = connectionOrder
    .map((id) => connections[id])
    .filter((c): c is Connection => c !== undefined);

  // Mouse-based drag and drop (more reliable in Tauri than HTML5 drag API)
  const [draggedId, setDraggedId] = useState<string | null>(null);
  const [dragOverId, setDragOverId] = useState<string | null>(null);
  const [dragPosition, setDragPosition] = useState<{ x: number; y: number } | null>(null);
  const connectionRefsRef = useRef<Map<string, HTMLDivElement>>(new Map());

  const handleConnect = useCallback(
    async (connection: Connection) => {
      updateConnectionStatus(connection.config.id, 'connecting');

      try {
        const result = await tauri.connectPostgres(connection.config.id);

        if (result.status === 'connected') {
          updateConnectionStatus(connection.config.id, 'connected', undefined, result.latency_ms);
          onSchemaRefresh?.(connection.config.id);
        } else if (result.status === 'error') {
          updateConnectionStatus(connection.config.id, 'error', result.error || 'Connection failed');
        } else {
          updateConnectionStatus(connection.config.id, result.status);
        }
      } catch (err) {
        const errorMessage = err instanceof Error ? err.message : String(err);
        updateConnectionStatus(connection.config.id, 'error', errorMessage);
      }
    },
    [updateConnectionStatus, onSchemaRefresh]
  );

  const handleDisconnect = useCallback(
    async (connection: Connection) => {
      try {
        await tauri.disconnectPostgres(connection.config.id);
      } catch (err) {
        console.error('Disconnect error:', err);
      }
      updateConnectionStatus(connection.config.id, 'disconnected');
    },
    [updateConnectionStatus]
  );

  const handleRefresh = useCallback(
    (connection: Connection) => {
      if (connection.status === 'connected') {
        onSchemaRefresh?.(connection.config.id);
      }
    },
    [onSchemaRefresh]
  );

  const handleDelete = useCallback(
    async (connection: Connection) => {
      const connectionId = connection.config.id;
      const connectionName = connection.config.name;
      const wasConnected = connection.status === 'connected';

      const confirmed = await ask(`Delete connection "${connectionName}"?`, {
        title: 'Delete Connection',
        kind: 'warning',
      });

      if (!confirmed) {
        return;
      }

      // Disconnect first if connected
      if (wasConnected) {
        try {
          await tauri.disconnectPostgres(connectionId);
        } catch (err) {
          console.error('Disconnect error:', err);
        }
      }

      // Delete from backend
      try {
        await tauri.deleteConnection(connectionId);
        // Remove from store only after successful backend deletion
        removeConnection(connectionId);
      } catch (err) {
        console.error('Delete error:', err);
      }
    },
    [removeConnection]
  );

  const handleDuplicate = useCallback(
    async (connection: Connection) => {
      const newConfig = {
        ...connection.config,
        id: crypto.randomUUID(),
        name: `${connection.config.name} (copy)`,
        password: '', // Don't copy password from keychain
      };

      try {
        await tauri.saveConnection(newConfig);
        addConnection(newConfig);
      } catch (err) {
        console.error('Failed to duplicate connection:', err);
      }
    },
    [addConnection]
  );

  // Mouse-based drag start
  const handleDragStart = useCallback((e: React.MouseEvent, connectionId: string) => {
    e.preventDefault();
    e.stopPropagation();
    setDraggedId(connectionId);
    setDragPosition({ x: e.clientX, y: e.clientY });
  }, []);

  // Store connection element refs
  const setConnectionRef = useCallback((connectionId: string, element: HTMLDivElement | null) => {
    if (element) {
      connectionRefsRef.current.set(connectionId, element);
    } else {
      connectionRefsRef.current.delete(connectionId);
    }
  }, []);

  // Mouse-based drag tracking (document level)
  useEffect(() => {
    if (!draggedId) return;

    const handleMouseMove = (e: MouseEvent) => {
      setDragPosition({ x: e.clientX, y: e.clientY });

      // Find which connection the mouse is over
      let foundConnectionId: string | null = null;
      let closestDistance = Infinity;

      connectionRefsRef.current.forEach((element, connId) => {
        if (element && connId !== draggedId) {
          const rect = element.getBoundingClientRect();
          const centerY = rect.top + rect.height / 2;

          // Check if cursor is within horizontal bounds
          if (e.clientX >= rect.left - 10 && e.clientX <= rect.right + 10) {
            // Find the connection whose center is closest to the cursor
            const distance = Math.abs(e.clientY - centerY);
            if (distance < closestDistance && distance < 40) {
              closestDistance = distance;
              foundConnectionId = connId;
            }
          }
        }
      });

      setDragOverId(foundConnectionId);
    };

    const handleMouseUp = async () => {
      if (draggedId && dragOverId !== null && draggedId !== dragOverId) {
        const newOrder = [...connectionOrder];
        const sourceIndex = newOrder.indexOf(draggedId);
        const targetIndex = newOrder.indexOf(dragOverId);

        if (sourceIndex !== -1 && targetIndex !== -1) {
          // Remove from old position
          newOrder.splice(sourceIndex, 1);
          // Insert at new position
          newOrder.splice(targetIndex, 0, draggedId);

          // Update local state immediately
          reorderConnections(newOrder);

          // Persist to backend
          try {
            await tauri.reorderConnections(newOrder);
          } catch (err) {
            console.error('Failed to persist connection order:', err);
          }
        }
      }

      setDraggedId(null);
      setDragOverId(null);
      setDragPosition(null);
    };

    document.addEventListener('mousemove', handleMouseMove);
    document.addEventListener('mouseup', handleMouseUp);

    return () => {
      document.removeEventListener('mousemove', handleMouseMove);
      document.removeEventListener('mouseup', handleMouseUp);
    };
  }, [draggedId, dragOverId, connectionOrder, reorderConnections]);

  return (
    <div className="w-[48px] flex flex-col items-center bg-theme-bg-elevated border-r border-theme-border-primary">
      {/* Connection icons */}
      <div className="flex-1 flex flex-col items-center gap-1 overflow-y-auto py-2 no-drag">
        {orderedConnections.map((connection) => (
          <ConnectionIcon
            key={connection.config.id}
            connection={connection}
            isActive={activeConnectionId === connection.config.id}
            isDragging={draggedId === connection.config.id}
            isDragOver={dragOverId === connection.config.id && draggedId !== connection.config.id}
            onConnect={handleConnect}
            onDisconnect={handleDisconnect}
            onEdit={onEditConnection}
            onRefresh={handleRefresh}
            onDelete={handleDelete}
            onDuplicate={handleDuplicate}
            onDragStart={handleDragStart}
            setRef={setConnectionRef}
          />
        ))}
      </div>

      {/* Drag indicator overlay */}
      {draggedId && dragPosition && (
        <div className="fixed inset-0 z-40 pointer-events-none">
          <div
            className={cn(
              'absolute px-2 py-1 rounded text-xs shadow-lg whitespace-nowrap',
              'transform -translate-x-1/2',
              dragOverId !== null
                ? 'bg-blue-600 text-white border border-blue-500'
                : 'bg-theme-bg-elevated text-theme-text-secondary border border-theme-border-secondary'
            )}
            style={{
              left: dragPosition.x,
              top: dragPosition.y + 16,
            }}
          >
            {dragOverId !== null
              ? `Move ${connections[draggedId]?.config.name || 'connection'}`
              : 'Drag to reorder...'}
          </div>
        </div>
      )}

      {/* Add connection button */}
      <div className="py-2 border-t border-theme-border-primary">
        <button
          onClick={onAddConnection}
          className={cn(
            'w-8 h-8 rounded-lg flex items-center justify-center transition-all duration-200',
            'hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary no-drag'
          )}
          title="Add new connection"
        >
          <Plus className="w-4 h-4" />
        </button>
      </div>
    </div>
  );
}
