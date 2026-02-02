import { cn } from '@/lib/cn';
import { useConnectionStore } from '@/stores/connectionStore';
import { useEditorStore } from '@/stores/editorStore';

export function StatusBar() {
  const activeConnection = useConnectionStore((state) => state.getActiveConnection());
  const activeTab = useEditorStore((state) => state.getActiveTab());

  const statusColors = {
    connected: 'bg-emerald-500',
    disconnected: 'bg-gray-400',
    connecting: 'bg-amber-500 animate-pulse',
    error: 'bg-red-500',
  };

  return (
    <div className="h-7 flex items-center justify-between px-4 text-xs bg-theme-bg-elevated border-t border-theme-border-primary">
      <div className="flex items-center gap-4">
        {activeConnection ? (
          <div className="flex items-center gap-2">
            <div className={cn('w-2 h-2 rounded-full', statusColors[activeConnection.status])} />
            <span className="text-theme-text-secondary">
              {activeConnection.status === 'connected'
                ? activeConnection.config.name
                : activeConnection.status === 'connecting'
                ? `Connecting to ${activeConnection.config.name}...`
                : `${activeConnection.config.name} (disconnected)`}
            </span>
            {activeConnection.latency !== undefined && activeConnection.status === 'connected' && (
              <span className="text-theme-text-tertiary">{activeConnection.latency}ms</span>
            )}
          </div>
        ) : (
          <span className="text-theme-text-tertiary">No connection selected</span>
        )}
      </div>

      <div className="flex items-center gap-4 text-theme-text-tertiary">
        {activeTab?.results && (
          <span>
            {activeTab.results.rowCount.toLocaleString()} rows
            {activeTab.executionTime !== null && ` · ${activeTab.executionTime}ms`}
          </span>
        )}
        <span>Pharos v0.9.1</span>
      </div>
    </div>
  );
}
