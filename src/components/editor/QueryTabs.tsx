import { useState, useCallback, useEffect, useRef, useMemo } from 'react';
import { Plus, X, FileCode, ChevronDown, Loader2, Copy, Pencil } from 'lucide-react';
import { cn } from '@/lib/cn';
import { useEditorStore } from '@/stores/editorStore';
import { useConnectionStore } from '@/stores/connectionStore';
import { useContextMenuPosition } from '@/hooks/useContextMenuPosition';

const MIN_TAB_WIDTH = 80;
const MAX_TAB_WIDTH = 200;

export function QueryTabs() {
  const tabs = useEditorStore((state) => state.tabs);
  const activeTabId = useEditorStore((state) => state.activeTabId);
  const createTab = useEditorStore((state) => state.createTab);
  const closeTab = useEditorStore((state) => state.closeTab);
  const closeOtherTabs = useEditorStore((state) => state.closeOtherTabs);
  const closeTabsToRight = useEditorStore((state) => state.closeTabsToRight);
  const closeAllTabs = useEditorStore((state) => state.closeAllTabs);
  const duplicateTab = useEditorStore((state) => state.duplicateTab);
  const reorderTabs = useEditorStore((state) => state.reorderTabs);
  const pushClosedTab = useEditorStore((state) => state.pushClosedTab);
  const setActiveTab = useEditorStore((state) => state.setActiveTab);
  const updateTabName = useEditorStore((state) => state.updateTabName);
  const activeConnectionId = useConnectionStore((state) => state.activeConnectionId);

  // Container measurement for auto-shrink
  const tabsContainerRef = useRef<HTMLDivElement | null>(null);
  const [containerWidth, setContainerWidth] = useState(0);

  // Tab list dropdown
  const [showTabList, setShowTabList] = useState(false);
  const dropdownRef = useRef<HTMLDivElement | null>(null);
  const dropdownButtonRef = useRef<HTMLButtonElement | null>(null);

  // Context menu
  const [contextMenu, setContextMenu] = useState<{ tabId: string; x: number; y: number } | null>(null);
  const contextMenuRef = useRef<HTMLDivElement | null>(null);
  const contextMenuPositionRef = useContextMenuPosition(contextMenu?.x, contextMenu?.y, contextMenuRef);

  // Inline rename
  const [renamingTabId, setRenamingTabId] = useState<string | null>(null);
  const [renameValue, setRenameValue] = useState('');
  const renameInputRef = useRef<HTMLInputElement | null>(null);

  // Drag to reorder
  const [draggingTabId, setDraggingTabId] = useState<string | null>(null);
  const [dropTargetIndex, setDropTargetIndex] = useState<number | null>(null);
  const dropTargetIndexRef = useRef<number | null>(null);
  const dragStartX = useRef(0);
  const hasDragStarted = useRef(false);
  const autoScrollInterval = useRef<ReturnType<typeof setInterval> | null>(null);

  // Measure container width
  useEffect(() => {
    const el = tabsContainerRef.current;
    if (!el) return;
    const observer = new ResizeObserver(([entry]) => {
      setContainerWidth(entry.contentRect.width);
    });
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  // Compute tab width
  const computedTabWidth = useMemo(() => {
    if (tabs.length === 0) return MAX_TAB_WIDTH;
    const width = Math.floor(containerWidth / tabs.length);
    return Math.max(MIN_TAB_WIDTH, Math.min(MAX_TAB_WIDTH, width));
  }, [tabs.length, containerWidth]);

  // Scroll active tab into view
  useEffect(() => {
    if (!activeTabId) return;
    const tabEl = tabsContainerRef.current?.querySelector(`[data-tab-id="${activeTabId}"]`);
    tabEl?.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'smooth' });
  }, [activeTabId]);

  // Close tab list dropdown on outside click
  useEffect(() => {
    if (!showTabList) return;
    const handleClickOutside = (e: MouseEvent) => {
      if (
        dropdownRef.current && !dropdownRef.current.contains(e.target as Node) &&
        dropdownButtonRef.current && !dropdownButtonRef.current.contains(e.target as Node)
      ) {
        setShowTabList(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [showTabList]);

  // Close context menu on outside click
  useEffect(() => {
    if (!contextMenu) return;
    const handleClickOutside = (e: MouseEvent) => {
      if (contextMenuRef.current && !contextMenuRef.current.contains(e.target as Node)) {
        setContextMenu(null);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [contextMenu]);

  // Focus rename input when entering rename mode
  useEffect(() => {
    if (renamingTabId) {
      renameInputRef.current?.focus();
      renameInputRef.current?.select();
    }
  }, [renamingTabId]);

  const handleNewTab = () => {
    createTab(activeConnectionId);
  };

  const handleCloseTab = (e: React.MouseEvent, tabId: string) => {
    e.stopPropagation();
    const tab = tabs.find((t) => t.id === tabId);
    if (tab) pushClosedTab({ name: tab.name, sql: tab.sql });
    closeTab(tabId);
  };

  const handleTabContextMenu = (e: React.MouseEvent, tabId: string) => {
    e.preventDefault();
    setContextMenu({ tabId, x: e.clientX, y: e.clientY });
  };

  // Context menu actions
  const handleContextClose = () => {
    if (!contextMenu) return;
    const tab = tabs.find((t) => t.id === contextMenu.tabId);
    if (tab) pushClosedTab({ name: tab.name, sql: tab.sql });
    closeTab(contextMenu.tabId);
    setContextMenu(null);
  };

  const handleContextCloseOthers = () => {
    if (!contextMenu) return;
    closeOtherTabs(contextMenu.tabId);
    setContextMenu(null);
  };

  const handleContextCloseToRight = () => {
    if (!contextMenu) return;
    closeTabsToRight(contextMenu.tabId);
    setContextMenu(null);
  };

  const handleContextCloseAll = () => {
    closeAllTabs();
    setContextMenu(null);
  };

  const handleContextDuplicate = () => {
    if (!contextMenu) return;
    duplicateTab(contextMenu.tabId);
    setContextMenu(null);
  };

  const handleContextRename = () => {
    if (!contextMenu) return;
    const tab = tabs.find((t) => t.id === contextMenu.tabId);
    if (tab) {
      setRenamingTabId(contextMenu.tabId);
      setRenameValue(tab.name);
    }
    setContextMenu(null);
  };

  const commitRename = () => {
    if (renamingTabId && renameValue.trim()) {
      updateTabName(renamingTabId, renameValue.trim());
    }
    setRenamingTabId(null);
  };

  const cancelRename = () => {
    setRenamingTabId(null);
  };

  // Drag to reorder
  const updateDropTarget = useCallback((clientX: number) => {
    const container = tabsContainerRef.current;
    if (!container) return;
    const tabEls = container.querySelectorAll<HTMLElement>('[data-tab-id]');
    let targetIndex = tabs.length;

    for (let i = 0; i < tabEls.length; i++) {
      const rect = tabEls[i].getBoundingClientRect();
      const midX = rect.left + rect.width / 2;
      if (clientX < midX) {
        targetIndex = i;
        break;
      }
    }

    dropTargetIndexRef.current = targetIndex;
    setDropTargetIndex(targetIndex);
  }, [tabs.length]);

  const startAutoScroll = useCallback((clientX: number) => {
    const container = tabsContainerRef.current;
    if (!container) return;

    if (autoScrollInterval.current) {
      clearInterval(autoScrollInterval.current);
      autoScrollInterval.current = null;
    }

    const rect = container.getBoundingClientRect();
    const edgeThreshold = 40;

    if (clientX < rect.left + edgeThreshold) {
      autoScrollInterval.current = setInterval(() => {
        container.scrollLeft -= 8;
      }, 16);
    } else if (clientX > rect.right - edgeThreshold) {
      autoScrollInterval.current = setInterval(() => {
        container.scrollLeft += 8;
      }, 16);
    }
  }, []);

  const stopAutoScroll = useCallback(() => {
    if (autoScrollInterval.current) {
      clearInterval(autoScrollInterval.current);
      autoScrollInterval.current = null;
    }
  }, []);

  const handleTabMouseDown = useCallback((e: React.MouseEvent, tabId: string) => {
    if (e.button !== 0) return;
    // Don't start drag from close button
    if ((e.target as HTMLElement).closest('button')) return;

    dragStartX.current = e.clientX;
    hasDragStarted.current = false;
    const currentTabId = tabId;

    const handleMouseMove = (moveEvent: MouseEvent) => {
      if (!hasDragStarted.current && Math.abs(moveEvent.clientX - dragStartX.current) > 5) {
        hasDragStarted.current = true;
        setDraggingTabId(currentTabId);
      }
      if (hasDragStarted.current) {
        updateDropTarget(moveEvent.clientX);
        startAutoScroll(moveEvent.clientX);
      }
    };

    const handleMouseUp = () => {
      stopAutoScroll();
      if (hasDragStarted.current) {
        const fromIndex = tabs.findIndex((t) => t.id === currentTabId);
        const toIndex = dropTargetIndexRef.current;
        if (fromIndex !== -1 && toIndex !== null && fromIndex !== toIndex) {
          const adjustedIndex = toIndex > fromIndex ? toIndex - 1 : toIndex;
          reorderTabs(fromIndex, adjustedIndex);
        }
      }
      setDraggingTabId(null);
      setDropTargetIndex(null);
      dropTargetIndexRef.current = null;
      document.removeEventListener('mousemove', handleMouseMove);
      document.removeEventListener('mouseup', handleMouseUp);
    };

    document.addEventListener('mousemove', handleMouseMove);
    document.addEventListener('mouseup', handleMouseUp);
  }, [tabs, updateDropTarget, startAutoScroll, stopAutoScroll, reorderTabs]);

  // Compute drop indicator position
  const dropIndicatorLeft = useMemo(() => {
    if (dropTargetIndex === null || !tabsContainerRef.current) return 0;
    const tabEls = tabsContainerRef.current.querySelectorAll<HTMLElement>('[data-tab-id]');
    if (dropTargetIndex >= tabEls.length) {
      const lastEl = tabEls[tabEls.length - 1];
      if (!lastEl) return 0;
      const containerRect = tabsContainerRef.current.getBoundingClientRect();
      return lastEl.getBoundingClientRect().right - containerRect.left + tabsContainerRef.current.scrollLeft;
    }
    const targetEl = tabEls[dropTargetIndex];
    const containerRect = tabsContainerRef.current.getBoundingClientRect();
    return targetEl.getBoundingClientRect().left - containerRect.left + tabsContainerRef.current.scrollLeft;
  }, [dropTargetIndex, draggingTabId]);

  // Dropdown position
  const [dropdownPos, setDropdownPos] = useState({ top: 0, right: 0 });
  useEffect(() => {
    if (showTabList && dropdownButtonRef.current) {
      const rect = dropdownButtonRef.current.getBoundingClientRect();
      setDropdownPos({ top: rect.bottom + 2, right: window.innerWidth - rect.right });
    }
  }, [showTabList]);

  const contextMenuTabIndex = contextMenu ? tabs.findIndex((t) => t.id === contextMenu.tabId) : -1;

  const menuItemClass = "w-full flex items-center gap-2 px-3 py-1.5 text-sm text-theme-text-secondary hover:bg-theme-bg-hover transition-colors text-left";

  return (
    <>
      <div className="flex items-center h-10 bg-theme-bg-surface border-b border-theme-border-primary">
        {/* Scrollable tab area */}
        <div
          ref={tabsContainerRef}
          className="relative flex-1 flex items-center h-full min-w-0 overflow-x-auto"
          style={{ scrollbarWidth: 'none' }}
        >
          {tabs.map((tab) => (
            <div
              key={tab.id}
              data-tab-id={tab.id}
              className={cn(
                'flex-shrink-0 h-full',
                draggingTabId === tab.id && 'opacity-50',
              )}
              style={{ width: computedTabWidth }}
              onMouseDown={(e) => handleTabMouseDown(e, tab.id)}
              onContextMenu={(e) => handleTabContextMenu(e, tab.id)}
            >
              <div
                onClick={() => {
                  if (!hasDragStarted.current) setActiveTab(tab.id);
                }}
                className={cn(
                  'group flex items-center gap-2 px-3 h-full cursor-pointer',
                  'transition-colors duration-150',
                  tab.id === activeTabId
                    ? 'bg-theme-bg-active text-theme-text-primary'
                    : 'text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover'
                )}
              >
                <FileCode className="w-4 h-4 flex-shrink-0 text-theme-text-tertiary" />
                {renamingTabId === tab.id ? (
                  <input
                    ref={renameInputRef}
                    value={renameValue}
                    onChange={(e) => setRenameValue(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') commitRename();
                      if (e.key === 'Escape') cancelRename();
                    }}
                    onBlur={commitRename}
                    className="text-sm bg-transparent border border-theme-border-secondary rounded px-1 py-0 flex-1 min-w-0 outline-none text-theme-text-primary"
                    onClick={(e) => e.stopPropagation()}
                  />
                ) : (
                  <span className="text-sm truncate flex-1">
                    {tab.name}
                    {tab.isDirty && <span className="text-theme-text-muted ml-1">*</span>}
                  </span>
                )}
                {tab.isExecuting ? (
                  <Loader2 className="w-3.5 h-3.5 flex-shrink-0 animate-spin text-theme-text-tertiary" />
                ) : (
                  <button
                    onClick={(e) => handleCloseTab(e, tab.id)}
                    className={cn(
                      'p-0.5 rounded opacity-0 group-hover:opacity-100 transition-opacity flex-shrink-0',
                      'hover:bg-theme-bg-hover'
                    )}
                  >
                    <X className="w-3.5 h-3.5" />
                  </button>
                )}
              </div>
            </div>
          ))}

          {/* Drop indicator */}
          {draggingTabId !== null && dropTargetIndex !== null && (
            <div
              className="absolute top-1 bottom-1 w-0.5 bg-blue-500 rounded-full z-20 pointer-events-none"
              style={{ left: dropIndicatorLeft }}
            />
          )}
        </div>

        {/* Tab list dropdown button */}
        {tabs.length > 1 && (
          <button
            ref={dropdownButtonRef}
            onClick={() => setShowTabList(!showTabList)}
            className={cn(
              'flex items-center justify-center w-8 h-full flex-shrink-0 transition-colors',
              'text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover',
              showTabList && 'bg-theme-bg-hover text-theme-text-primary'
            )}
            title="Show all tabs"
          >
            <ChevronDown className="w-4 h-4" />
          </button>
        )}

        {/* New tab button - always visible */}
        <button
          onClick={handleNewTab}
          className="flex items-center justify-center w-10 h-full flex-shrink-0 text-theme-text-tertiary hover:text-theme-text-primary hover:bg-theme-bg-hover transition-colors"
          title="New Query Tab"
        >
          <Plus className="w-4 h-4" />
        </button>
      </div>

      {/* Tab list dropdown */}
      {showTabList && (
        <div
          ref={dropdownRef}
          className="fixed z-50 min-w-[200px] max-w-[320px] max-h-[300px] overflow-y-auto py-1 bg-theme-bg-elevated border border-theme-border-secondary rounded-lg shadow-xl"
          style={{ top: dropdownPos.top, right: dropdownPos.right }}
        >
          {tabs.map((tab) => (
            <button
              key={tab.id}
              onClick={() => { setActiveTab(tab.id); setShowTabList(false); }}
              className={cn(
                'w-full flex items-center gap-2 px-3 py-1.5 text-sm transition-colors',
                tab.id === activeTabId
                  ? 'bg-theme-bg-active text-theme-text-primary'
                  : 'text-theme-text-secondary hover:bg-theme-bg-hover'
              )}
            >
              <FileCode className="w-4 h-4 flex-shrink-0 text-theme-text-tertiary" />
              <span className="truncate flex-1 text-left">{tab.name}</span>
              {tab.isDirty && <span className="text-theme-text-muted flex-shrink-0">*</span>}
              {tab.isExecuting && <Loader2 className="w-3 h-3 animate-spin flex-shrink-0" />}
            </button>
          ))}
        </div>
      )}

      {/* Context menu */}
      {contextMenu && (
        <div
          ref={contextMenuPositionRef}
          className="fixed z-50 min-w-[180px] py-1 bg-theme-bg-elevated border border-theme-border-secondary rounded-lg shadow-xl"
          style={{ left: contextMenu.x, top: contextMenu.y }}
        >
          <button className={menuItemClass} onClick={handleContextClose}>
            <X className="w-4 h-4" />
            Close
          </button>
          <button
            className={cn(menuItemClass, tabs.length <= 1 && 'opacity-40 pointer-events-none')}
            onClick={handleContextCloseOthers}
          >
            Close Others
          </button>
          <button
            className={cn(menuItemClass, contextMenuTabIndex >= tabs.length - 1 && 'opacity-40 pointer-events-none')}
            onClick={handleContextCloseToRight}
          >
            Close to the Right
          </button>
          <button className={menuItemClass} onClick={handleContextCloseAll}>
            Close All
          </button>
          <div className="my-1 border-t border-theme-border-primary" />
          <button className={menuItemClass} onClick={handleContextDuplicate}>
            <Copy className="w-4 h-4" />
            Duplicate Tab
          </button>
          <button className={menuItemClass} onClick={handleContextRename}>
            <Pencil className="w-4 h-4" />
            Rename Tab
          </button>
        </div>
      )}
    </>
  );
}
