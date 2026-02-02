import { Plus, X, FileCode } from 'lucide-react';
import { cn } from '@/lib/cn';
import { useEditorStore } from '@/stores/editorStore';
import { useConnectionStore } from '@/stores/connectionStore';

export function QueryTabs() {
  const tabs = useEditorStore((state) => state.tabs);
  const activeTabId = useEditorStore((state) => state.activeTabId);
  const createTab = useEditorStore((state) => state.createTab);
  const closeTab = useEditorStore((state) => state.closeTab);
  const setActiveTab = useEditorStore((state) => state.setActiveTab);
  const activeConnectionId = useConnectionStore((state) => state.activeConnectionId);

  const handleNewTab = () => {
    createTab(activeConnectionId);
  };

  const handleCloseTab = (e: React.MouseEvent, tabId: string) => {
    e.stopPropagation();
    closeTab(tabId);
  };

  return (
    <div className="flex items-center h-10 bg-theme-bg-surface border-b border-theme-border-primary overflow-x-auto">
      {tabs.map((tab) => (
        <div
          key={tab.id}
          onClick={() => setActiveTab(tab.id)}
          className={cn(
            'group flex items-center gap-2 px-4 h-full cursor-pointer',
            'border-r border-theme-border-primary min-w-[140px] max-w-[200px]',
            'transition-colors duration-150',
            tab.id === activeTabId
              ? 'bg-theme-bg-active text-theme-text-primary'
              : 'text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover'
          )}
        >
          <FileCode className="w-4 h-4 flex-shrink-0 text-theme-text-tertiary" />
          <span className="text-sm truncate flex-1">
            {tab.name}
            {tab.isDirty && <span className="text-theme-text-muted ml-1">*</span>}
          </span>
          <button
            onClick={(e) => handleCloseTab(e, tab.id)}
            className={cn(
              'p-0.5 rounded opacity-0 group-hover:opacity-100 transition-opacity',
              'hover:bg-theme-bg-hover'
            )}
          >
            <X className="w-3.5 h-3.5" />
          </button>
        </div>
      ))}

      <button
        onClick={handleNewTab}
        className="flex items-center justify-center w-10 h-full text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover transition-colors"
        title="New Query Tab"
      >
        <Plus className="w-4 h-4" />
      </button>
    </div>
  );
}
