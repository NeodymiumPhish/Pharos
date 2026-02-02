import { useState, useCallback, useEffect, useRef } from 'react';
import { Plus, X, FileCode } from 'lucide-react';
import { cn } from '@/lib/cn';
import { useEditorStore } from '@/stores/editorStore';
import { useConnectionStore } from '@/stores/connectionStore';

const DEFAULT_TAB_WIDTH = 160;
const MIN_TAB_WIDTH = 100;
const MAX_TAB_WIDTH = 300;

export function QueryTabs() {
  const tabs = useEditorStore((state) => state.tabs);
  const activeTabId = useEditorStore((state) => state.activeTabId);
  const createTab = useEditorStore((state) => state.createTab);
  const closeTab = useEditorStore((state) => state.closeTab);
  const setActiveTab = useEditorStore((state) => state.setActiveTab);
  const activeConnectionId = useConnectionStore((state) => state.activeConnectionId);

  const [tabWidths, setTabWidths] = useState<Record<string, number>>({});
  const [resizingTabId, setResizingTabId] = useState<string | null>(null);
  const resizeStartX = useRef(0);
  const resizeStartWidth = useRef(0);

  const handleNewTab = () => {
    createTab(activeConnectionId);
  };

  const handleCloseTab = (e: React.MouseEvent, tabId: string) => {
    e.stopPropagation();
    closeTab(tabId);
  };

  const handleResizeStart = useCallback((e: React.MouseEvent, tabId: string) => {
    e.preventDefault();
    e.stopPropagation();
    setResizingTabId(tabId);
    resizeStartX.current = e.clientX;
    resizeStartWidth.current = tabWidths[tabId] ?? DEFAULT_TAB_WIDTH;
  }, [tabWidths]);

  useEffect(() => {
    if (!resizingTabId) return;

    const handleMouseMove = (e: MouseEvent) => {
      const delta = e.clientX - resizeStartX.current;
      const newWidth = Math.max(MIN_TAB_WIDTH, Math.min(MAX_TAB_WIDTH, resizeStartWidth.current + delta));
      setTabWidths((prev) => ({
        ...prev,
        [resizingTabId]: newWidth,
      }));
    };

    const handleMouseUp = () => {
      setResizingTabId(null);
    };

    document.addEventListener('mousemove', handleMouseMove);
    document.addEventListener('mouseup', handleMouseUp);

    return () => {
      document.removeEventListener('mousemove', handleMouseMove);
      document.removeEventListener('mouseup', handleMouseUp);
    };
  }, [resizingTabId]);

  const getTabWidth = (tabId: string) => tabWidths[tabId] ?? DEFAULT_TAB_WIDTH;

  return (
    <div className="flex items-center h-10 bg-theme-bg-surface border-b border-theme-border-primary overflow-x-auto">
      {tabs.map((tab) => (
        <div
          key={tab.id}
          className="relative flex-shrink-0 h-full"
          style={{ width: getTabWidth(tab.id) }}
        >
          <div
            onClick={() => setActiveTab(tab.id)}
            className={cn(
              'group flex items-center gap-2 px-4 h-full cursor-pointer',
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
          {/* Resize handle */}
          <div
            onMouseDown={(e) => handleResizeStart(e, tab.id)}
            className={cn(
              'absolute right-0 top-0 bottom-0 w-1 cursor-col-resize z-10',
              'hover:bg-theme-bg-active',
              resizingTabId === tab.id && 'bg-theme-bg-active'
            )}
          />
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
