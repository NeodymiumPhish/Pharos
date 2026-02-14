import { useState, useEffect, useRef } from 'react';
import { ChevronDown, Plus, Power, PowerOff, RefreshCw, Pencil, Copy, Trash2 } from 'lucide-react';
import { cn } from '@/lib/cn';
import { useConnectionStore } from '@/stores/connectionStore';
import { useConnectionActions } from '@/hooks/useConnectionActions';
import type { Connection } from '@/lib/types';

interface ConnectionSelectorProps {
  onAddConnection: () => void;
  onEditConnection: (connection: Connection) => void;
  onSchemaRefresh?: () => void;
}

export function ConnectionSelector({
  onAddConnection,
  onEditConnection,
  onSchemaRefresh,
}: ConnectionSelectorProps) {
  const activeConnection = useConnectionStore((state) => state.getActiveConnection());
  const orderedConnections = useConnectionStore((state) => state.getOrderedConnections());
  const setActiveConnection = useConnectionStore((state) => state.setActiveConnection);
  const { handleConnect, handleDisconnect, handleRefresh, handleDelete, handleDuplicate } =
    useConnectionActions(onSchemaRefresh ? () => onSchemaRefresh() : undefined);

  const [isOpen, setIsOpen] = useState(false);
  const dropdownRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!isOpen) return;
    const handleClickOutside = (e: MouseEvent) => {
      if (dropdownRef.current && !dropdownRef.current.contains(e.target as Node)) {
        setIsOpen(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [isOpen]);

  const statusColors: Record<string, string> = {
    connected: 'bg-emerald-500',
    disconnected: 'bg-gray-400',
    connecting: 'bg-amber-500 animate-pulse',
    error: 'bg-red-500',
  };

  return (
    <div className="relative no-drag" ref={dropdownRef}>
      <button
        onClick={() => setIsOpen(!isOpen)}
        className={cn(
          'flex items-center gap-2 px-2.5 py-1.5 rounded-lg transition-colors w-full',
          'hover:bg-theme-bg-hover text-theme-text-primary text-sm',
          isOpen && 'bg-theme-bg-hover'
        )}
      >
        {activeConnection ? (
          <>
            <div className={cn('w-1.5 h-1.5 rounded-full flex-shrink-0', statusColors[activeConnection.status] || 'bg-gray-400')} />
            <span className="font-medium truncate">{activeConnection.config.name}</span>
            <span className="text-theme-text-tertiary">›</span>
            <span className="text-theme-text-secondary truncate">{activeConnection.config.database}</span>
          </>
        ) : (
          <span className="text-theme-text-muted">No connection</span>
        )}
        <ChevronDown className={cn(
          'w-3 h-3 text-theme-text-tertiary transition-transform ml-auto flex-shrink-0',
          isOpen && 'rotate-180'
        )} />
      </button>

      {isOpen && (
        <div className="absolute top-full left-0 right-0 mt-1 py-1.5 bg-theme-bg-elevated border border-theme-border-secondary rounded-xl shadow-2xl z-50 animate-dropdown min-w-[240px]">
          {orderedConnections.length === 0 ? (
            <div className="px-3 py-2 text-sm text-theme-text-muted">No connections configured</div>
          ) : (
            orderedConnections.map((connection) => (
              <ConnectionDropdownItem
                key={connection.config.id}
                connection={connection}
                isActive={activeConnection?.config.id === connection.config.id}
                onSelect={() => {
                  setActiveConnection(connection.config.id);
                  if (connection.status === 'disconnected' || connection.status === 'error') {
                    handleConnect(connection);
                  }
                  setIsOpen(false);
                }}
                onConnect={() => { handleConnect(connection); setIsOpen(false); }}
                onDisconnect={() => { handleDisconnect(connection); setIsOpen(false); }}
                onRefresh={() => { handleRefresh(connection); setIsOpen(false); }}
                onEdit={() => { onEditConnection(connection); setIsOpen(false); }}
                onDuplicate={() => { handleDuplicate(connection); setIsOpen(false); }}
                onDelete={() => { setIsOpen(false); setTimeout(() => handleDelete(connection), 10); }}
              />
            ))
          )}
          <div className="my-1 border-t border-theme-border-subtle" />
          <button
            className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors"
            onClick={() => {
              onAddConnection();
              setIsOpen(false);
            }}
          >
            <Plus className="w-4 h-4" />
            Add Connection
          </button>
        </div>
      )}
    </div>
  );
}

function ConnectionDropdownItem({
  connection,
  isActive,
  onSelect,
  onConnect,
  onDisconnect,
  onRefresh,
  onEdit,
  onDuplicate,
  onDelete,
}: {
  connection: Connection;
  isActive: boolean;
  onSelect: () => void;
  onConnect: () => void;
  onDisconnect: () => void;
  onRefresh: () => void;
  onEdit: () => void;
  onDuplicate: () => void;
  onDelete: () => void;
}) {
  const [showActions, setShowActions] = useState(false);
  const actionsRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!showActions) return;
    const handleClickOutside = (e: MouseEvent) => {
      if (actionsRef.current && !actionsRef.current.contains(e.target as Node)) {
        setShowActions(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [showActions]);

  const statusColors: Record<string, string> = {
    connected: 'bg-emerald-500',
    disconnected: 'bg-gray-400',
    connecting: 'bg-amber-500 animate-pulse',
    error: 'bg-red-500',
  };

  return (
    <div className="relative group">
      <button
        onClick={onSelect}
        onContextMenu={(e) => {
          e.preventDefault();
          setShowActions(true);
        }}
        className={cn(
          'w-full flex items-center gap-2.5 px-3 py-2 text-sm transition-colors',
          'hover:bg-theme-bg-hover',
          isActive ? 'text-theme-text-primary bg-theme-bg-active' : 'text-theme-text-secondary'
        )}
      >
        <div className={cn('w-2 h-2 rounded-full flex-shrink-0', statusColors[connection.status])} />
        <div className="flex-1 min-w-0 text-left">
          <div className="font-medium truncate">{connection.config.name}</div>
          <div className="text-[11px] text-theme-text-tertiary truncate">
            {connection.config.host}:{connection.config.port}/{connection.config.database}
          </div>
        </div>
        {connection.config.color && (
          <div className="w-2 h-2 rounded-full flex-shrink-0" style={{ backgroundColor: connection.config.color }} />
        )}
      </button>

      {showActions && (
        <div
          ref={actionsRef}
          className="absolute left-full top-0 ml-1 min-w-[160px] py-1 bg-theme-bg-elevated border border-theme-border-secondary rounded-xl shadow-2xl z-50 animate-dropdown"
        >
          {connection.status === 'connected' ? (
            <button className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors" onClick={() => { onDisconnect(); setShowActions(false); }}>
              <PowerOff className="w-3.5 h-3.5" /> Disconnect
            </button>
          ) : (
            <button className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors" onClick={() => { onConnect(); setShowActions(false); }} disabled={connection.status === 'connecting'}>
              <Power className="w-3.5 h-3.5" /> Connect
            </button>
          )}
          <button className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors disabled:opacity-40" onClick={() => { onRefresh(); setShowActions(false); }} disabled={connection.status !== 'connected'}>
            <RefreshCw className="w-3.5 h-3.5" /> Refresh Schema
          </button>
          <button className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors" onClick={() => { onEdit(); setShowActions(false); }}>
            <Pencil className="w-3.5 h-3.5" /> Edit
          </button>
          <button className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors" onClick={() => { onDuplicate(); setShowActions(false); }}>
            <Copy className="w-3.5 h-3.5" /> Duplicate
          </button>
          <div className="my-1 border-t border-theme-border-subtle" />
          <button className="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-red-400 hover:bg-theme-bg-hover transition-colors" onClick={() => { setShowActions(false); onDelete(); }}>
            <Trash2 className="w-3.5 h-3.5" /> Delete
          </button>
        </div>
      )}
    </div>
  );
}
