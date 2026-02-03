import { useState, useCallback, useEffect, useRef } from 'react';
import { Plus, Database, Power, PowerOff, RefreshCw, Trash2, Pencil } from 'lucide-react';
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

function ConnectionIcon({
  connection,
  isActive,
  onConnect,
  onDisconnect,
  onEdit,
  onRefresh,
  onDelete,
}: {
  connection: Connection;
  isActive: boolean;
  onConnect: (connection: Connection) => void;
  onDisconnect: (connection: Connection) => void;
  onEdit: (connection: Connection) => void;
  onRefresh: (connection: Connection) => void;
  onDelete: (connection: Connection) => void;
}) {
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
      <button
        onClick={handleClick}
        onContextMenu={handleContextMenu}
        className={cn(
          'relative w-9 h-11 rounded-lg flex flex-col items-center justify-center gap-0.5 transition-all duration-200',
          'hover:bg-theme-bg-hover',
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
        <span
          className={cn(
            'text-[8px] font-medium truncate max-w-[36px] text-center leading-tight',
            isActive ? 'text-theme-text-primary' : 'text-theme-text-tertiary'
          )}
        >
          {connection.config.name}
        </span>
      </button>

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
  const connections = useConnectionStore((state) => Object.values(state.connections));
  const activeConnectionId = useConnectionStore((state) => state.activeConnectionId);
  const updateConnectionStatus = useConnectionStore((state) => state.updateConnectionStatus);
  const removeConnection = useConnectionStore((state) => state.removeConnection);

  const handleConnect = useCallback(
    async (connection: Connection) => {
      updateConnectionStatus(connection.config.id, 'connecting');

      try {
        await tauri.connectPostgres(connection.config.id);
        updateConnectionStatus(connection.config.id, 'connected');
        onSchemaRefresh?.(connection.config.id);
      } catch (err) {
        const errorMessage = err instanceof Error ? err.message : 'Connection failed';
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

  return (
    <div className="w-[48px] flex flex-col items-center bg-theme-bg-elevated border-r border-theme-border-primary">
      {/* Connection icons */}
      <div className="flex-1 flex flex-col items-center gap-1 overflow-y-auto py-2 no-drag">
        {connections.map((connection) => (
          <ConnectionIcon
            key={connection.config.id}
            connection={connection}
            isActive={activeConnectionId === connection.config.id}
            onConnect={handleConnect}
            onDisconnect={handleDisconnect}
            onEdit={onEditConnection}
            onRefresh={handleRefresh}
            onDelete={handleDelete}
          />
        ))}
      </div>

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
