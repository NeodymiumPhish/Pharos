import { useEffect, useCallback, useRef, useState } from 'react';
import { Search, Trash2, Clock, Copy, X } from 'lucide-react';
import { useQueryHistoryStore } from '@/stores/queryHistoryStore';

interface QueryHistoryPanelProps {
  connectionId?: string;
  onQuerySelect?: (sql: string) => void;
}

function formatRelativeTime(isoDate: string): string {
  const date = new Date(isoDate);
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffMins = Math.floor(diffMs / 60000);
  const diffHours = Math.floor(diffMs / 3600000);
  const diffDays = Math.floor(diffMs / 86400000);

  if (diffMins < 1) return 'Just now';
  if (diffMins < 60) return `${diffMins}m ago`;
  if (diffHours < 24) return `${diffHours}h ago`;
  if (diffDays < 7) return `${diffDays}d ago`;
  return date.toLocaleDateString();
}

function getDateGroup(isoDate: string): string {
  const date = new Date(isoDate);
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const yesterday = new Date(today.getTime() - 86400000);
  const weekAgo = new Date(today.getTime() - 7 * 86400000);
  const monthAgo = new Date(today.getTime() - 30 * 86400000);

  if (date >= today) return 'Today';
  if (date >= yesterday) return 'Yesterday';
  if (date >= weekAgo) return 'This Week';
  if (date >= monthAgo) return 'This Month';
  return 'Older';
}

function truncateSql(sql: string, maxLen = 120): string {
  const oneLine = sql.replace(/\s+/g, ' ').trim();
  if (oneLine.length <= maxLen) return oneLine;
  return oneLine.slice(0, maxLen) + '...';
}

export function QueryHistoryPanel({ connectionId, onQuerySelect }: QueryHistoryPanelProps) {
  const {
    entries,
    isLoading,
    hasMore,
    search,
    loadHistory,
    loadMore,
    setSearch,
    deleteEntry,
    clearHistory,
  } = useQueryHistoryStore();

  const [searchInput, setSearchInput] = useState(search);
  const searchTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const [contextMenu, setContextMenu] = useState<{ entryId: string; x: number; y: number } | null>(null);

  // Load history on mount and when connectionId/search changes
  useEffect(() => {
    loadHistory(connectionId);
  }, [loadHistory, connectionId, search]);

  // Debounced search
  const handleSearchChange = useCallback((value: string) => {
    setSearchInput(value);
    if (searchTimerRef.current) clearTimeout(searchTimerRef.current);
    searchTimerRef.current = setTimeout(() => {
      setSearch(value);
    }, 300);
  }, [setSearch]);

  // Infinite scroll
  const handleScroll = useCallback(() => {
    if (!scrollRef.current || !hasMore || isLoading) return;
    const { scrollTop, scrollHeight, clientHeight } = scrollRef.current;
    if (scrollHeight - scrollTop - clientHeight < 100) {
      loadMore(connectionId);
    }
  }, [hasMore, isLoading, loadMore, connectionId]);

  // Context menu handlers
  const handleContextMenu = useCallback((e: React.MouseEvent, entryId: string) => {
    e.preventDefault();
    setContextMenu({ entryId, x: e.clientX, y: e.clientY });
  }, []);

  // Close context menu
  useEffect(() => {
    if (!contextMenu) return;
    const handleClick = () => setContextMenu(null);
    document.addEventListener('click', handleClick);
    return () => document.removeEventListener('click', handleClick);
  }, [contextMenu]);

  const handleCopySql = useCallback(async (sql: string) => {
    await navigator.clipboard.writeText(sql);
    setContextMenu(null);
  }, []);

  // Group entries by date
  const groupedEntries = entries.reduce<Record<string, typeof entries>>((groups, entry) => {
    const group = getDateGroup(entry.executedAt);
    if (!groups[group]) groups[group] = [];
    groups[group].push(entry);
    return groups;
  }, {});

  const groupOrder = ['Today', 'Yesterday', 'This Week', 'This Month', 'Older'];

  return (
    <div className="flex flex-col h-full">
      {/* Header */}
      <div className="flex items-center justify-between px-2 py-1.5 border-b border-theme-border-primary flex-shrink-0">
        <span className="text-xs text-theme-text-secondary font-medium">History</span>
        {entries.length > 0 && (
          <button
            onClick={() => clearHistory()}
            className="text-[10px] text-theme-text-muted hover:text-red-400 transition-colors"
            title="Clear all history"
          >
            Clear All
          </button>
        )}
      </div>

      {/* Search */}
      <div className="px-2 py-1.5 border-b border-theme-border-primary flex-shrink-0">
        <div className="flex items-center gap-1.5 px-2 py-1 rounded bg-theme-bg-surface border border-theme-border-primary">
          <Search className="w-3 h-3 text-theme-text-muted flex-shrink-0" />
          <input
            type="text"
            placeholder="Search history..."
            value={searchInput}
            onChange={(e) => handleSearchChange(e.target.value)}
            className="flex-1 text-[11px] bg-transparent text-theme-text-primary placeholder:text-theme-text-muted outline-none"
          />
          {searchInput && (
            <button
              onClick={() => { setSearchInput(''); setSearch(''); }}
              className="text-theme-text-muted hover:text-theme-text-secondary"
            >
              <X className="w-3 h-3" />
            </button>
          )}
        </div>
      </div>

      {/* Entries */}
      <div
        ref={scrollRef}
        className="flex-1 overflow-y-auto"
        onScroll={handleScroll}
      >
        {isLoading && entries.length === 0 ? (
          <div className="flex items-center justify-center py-8">
            <div className="w-4 h-4 border-2 border-theme-text-muted border-t-theme-text-secondary rounded-full animate-spin" />
          </div>
        ) : entries.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-8 text-theme-text-muted text-xs px-4 text-center">
            <Clock className="w-8 h-8 mb-2 opacity-30" />
            {search ? 'No matching queries found' : 'No query history yet'}
          </div>
        ) : (
          groupOrder
            .filter((group) => groupedEntries[group]?.length)
            .map((group) => (
              <div key={group}>
                <div className="sticky top-0 z-10 px-2 py-1 text-[10px] font-medium text-theme-text-muted bg-theme-bg-primary border-b border-theme-border-primary">
                  {group}
                </div>
                {groupedEntries[group].map((entry) => (
                  <div
                    key={entry.id}
                    className="px-2 py-1.5 hover:bg-theme-bg-hover cursor-pointer border-b border-theme-border-primary group"
                    onClick={() => onQuerySelect?.(entry.sql)}
                    onContextMenu={(e) => handleContextMenu(e, entry.id)}
                    title={entry.sql}
                  >
                    <div className="text-[11px] text-theme-text-secondary font-mono truncate leading-tight">
                      {truncateSql(entry.sql)}
                    </div>
                    <div className="flex items-center gap-2 mt-0.5">
                      <span className="text-[10px] text-theme-text-muted">
                        {formatRelativeTime(entry.executedAt)}
                      </span>
                      <span className="text-[10px] text-theme-text-muted">
                        {entry.executionTimeMs}ms
                      </span>
                      {entry.rowCount !== null && (
                        <span className="text-[10px] text-theme-text-muted">
                          {entry.rowCount.toLocaleString()} row{entry.rowCount !== 1 ? 's' : ''}
                        </span>
                      )}
                      <button
                        className="ml-auto opacity-0 group-hover:opacity-100 p-0.5 rounded hover:bg-theme-bg-active text-theme-text-muted hover:text-red-400 transition-all"
                        onClick={(e) => { e.stopPropagation(); deleteEntry(entry.id); }}
                        title="Delete entry"
                      >
                        <Trash2 className="w-3 h-3" />
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            ))
        )}
        {isLoading && entries.length > 0 && (
          <div className="flex items-center justify-center py-4">
            <div className="w-3 h-3 border-2 border-theme-text-muted border-t-theme-text-secondary rounded-full animate-spin" />
          </div>
        )}
      </div>

      {/* Context Menu */}
      {contextMenu && (
        <div
          className="fixed z-50 w-40 rounded-md border border-theme-border-secondary bg-theme-bg-elevated shadow-lg py-1"
          style={{ left: contextMenu.x, top: contextMenu.y }}
        >
          <button
            className="w-full text-left px-3 py-1.5 text-[11px] text-theme-text-secondary hover:bg-theme-bg-hover flex items-center gap-2"
            onClick={() => {
              const entry = entries.find((e) => e.id === contextMenu.entryId);
              if (entry) onQuerySelect?.(entry.sql);
              setContextMenu(null);
            }}
          >
            Open in Tab
          </button>
          <button
            className="w-full text-left px-3 py-1.5 text-[11px] text-theme-text-secondary hover:bg-theme-bg-hover flex items-center gap-2"
            onClick={() => {
              const entry = entries.find((e) => e.id === contextMenu.entryId);
              if (entry) handleCopySql(entry.sql);
            }}
          >
            <Copy className="w-3 h-3" /> Copy SQL
          </button>
          <button
            className="w-full text-left px-3 py-1.5 text-[11px] text-red-400 hover:bg-theme-bg-hover flex items-center gap-2"
            onClick={() => { deleteEntry(contextMenu.entryId); setContextMenu(null); }}
          >
            <Trash2 className="w-3 h-3" /> Delete
          </button>
        </div>
      )}
    </div>
  );
}
