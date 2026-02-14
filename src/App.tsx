import { useState, useEffect } from 'react';
import { PanelLeft, PanelLeftClose, Settings } from 'lucide-react';
import { listen } from '@tauri-apps/api/event';
import { cn } from '@/lib/cn';
import { ConnectionSelector } from '@/components/layout/Toolbar';
import { DatabaseNavigator } from '@/components/layout/DatabaseNavigator';
import { QueryWorkspace } from '@/components/layout/QueryWorkspace';
import { AddConnectionDialog } from '@/components/dialogs/AddConnectionDialog';
import { EditConnectionDialog } from '@/components/dialogs/EditConnectionDialog';
import { CloneTableDialog } from '@/components/dialogs/CloneTableDialog';
import { ImportDataDialog } from '@/components/dialogs/ImportDataDialog';
import { ExportDataDialog } from '@/components/dialogs/ExportDataDialog';
import { SettingsDialog } from '@/components/dialogs/SettingsDialog';
import { AboutDialog } from '@/components/dialogs/AboutDialog';
import { useConnectionStore } from '@/stores/connectionStore';
import { useEditorStore } from '@/stores/editorStore';
import type { Connection } from '@/lib/types';
import { useSettingsStore } from '@/stores/settingsStore';
import { useTheme } from '@/hooks/useTheme';
import { useWindowDrag } from '@/hooks/useWindowDrag';
import * as tauri from '@/lib/tauri';

function App() {
  const [sidebarWidth, setSidebarWidth] = useState(280);
  const [isSidebarOpen, setIsSidebarOpen] = useState(true);
  const [isAddConnectionOpen, setIsAddConnectionOpen] = useState(false);
  const [editingConnection, setEditingConnection] = useState<Connection | null>(null);
  const [isSettingsOpen, setIsSettingsOpen] = useState(false);
  const [isAboutOpen, setIsAboutOpen] = useState(false);
  const [schemaRefreshTrigger, setSchemaRefreshTrigger] = useState(0);

  // Table operation dialog state
  const [cloneTarget, setCloneTarget] = useState<{ schema: string; table: string; type: 'table' | 'view' } | null>(null);
  const [importTarget, setImportTarget] = useState<{ schema: string; table: string } | null>(null);
  const [exportTarget, setExportTarget] = useState<{ schema: string; table: string; type: 'table' | 'view' | 'foreign-table' } | null>(null);

  const activeConnectionId = useConnectionStore((state) => state.activeConnectionId);
  const [isResultsExpanded, setIsResultsExpanded] = useState(false);
  const [isSidebarResizing, setIsSidebarResizing] = useState(false);
  const setConnections = useConnectionStore((state) => state.setConnections);
  const setSettings = useSettingsStore((state) => state.setSettings);
  const { startDrag } = useWindowDrag();

  // Apply theme
  useTheme();

  // Load saved connections and settings on startup
  useEffect(() => {
    tauri.loadConnections()
      .then((configs) => {
        setConnections(configs);
      })
      .catch((err) => {
        console.error('Failed to load connections:', err);
      });

    tauri.loadSettings()
      .then((settings) => {
        setSettings(settings);
      })
      .catch((err) => {
        console.error('Failed to load settings:', err);
      });
  }, [setConnections, setSettings]);

  // Listen for menu events from Tauri
  useEffect(() => {
    const unlistenSettings = listen('menu-settings', () => {
      setIsSettingsOpen(true);
    });
    const unlistenAbout = listen('menu-about', () => {
      setIsAboutOpen(true);
    });

    return () => {
      unlistenSettings.then((unlisten) => unlisten());
      unlistenAbout.then((unlisten) => unlisten());
    };
  }, []);

  const handleSchemaRefresh = () => {
    setSchemaRefreshTrigger((prev) => prev + 1);
  };

  const handleViewRows = (schema: string, table: string, limit: number | null) => {
    if (!activeConnectionId) return;

    const sql = limit !== null
      ? `SELECT * FROM "${schema}"."${table}" LIMIT ${limit};`
      : `SELECT * FROM "${schema}"."${table}";`;

    const tabName = limit !== null ? `${table} (${limit})` : table;

    useEditorStore.getState().createTabWithContent(activeConnectionId, tabName, sql);
  };

  return (
    <div className="h-screen w-screen flex overflow-hidden bg-theme-bg-primary">
      {/* Sidebar — full height, extends under traffic lights */}
      {!isResultsExpanded && (
        <div
          className={cn(
            'flex-shrink-0 overflow-hidden bg-theme-bg-sidebar',
            !isSidebarResizing && 'transition-[width] duration-200 ease-in-out'
          )}
          style={{ width: isSidebarOpen ? sidebarWidth : 0 }}
        >
          <div
            className="h-full flex flex-col border-r border-theme-border-subtle"
            style={{ width: sidebarWidth, minWidth: sidebarWidth }}
          >
            {/* Sidebar title bar — drag region with traffic light inset */}
            <div
              onMouseDown={startDrag}
              className="flex-shrink-0 pt-[38px] px-2.5 pb-1 cursor-default"
            >
              <ConnectionSelector
                onAddConnection={() => setIsAddConnectionOpen(true)}
                onEditConnection={(connection) => setEditingConnection(connection)}
                onSchemaRefresh={() => handleSchemaRefresh()}
              />
            </div>

            {/* Schema dropdown, search, tree */}
            <DatabaseNavigator
              width={sidebarWidth}
              onWidthChange={setSidebarWidth}
              minWidth={200}
              maxWidth={500}
              refreshTrigger={schemaRefreshTrigger}
              onResizingChange={setIsSidebarResizing}
              onCloneTable={(schema, table, type) => setCloneTarget({ schema, table, type })}
              onImportData={(schema, table) => setImportTarget({ schema, table })}
              onExportData={(schema, table, type) => setExportTarget({ schema, table, type })}
              onViewRows={handleViewRows}
            />
          </div>
        </div>
      )}

      {/* Main content */}
      <div className="flex-1 flex flex-col min-w-0 overflow-hidden">
        {/* Title bar drag region — sidebar toggle + settings */}
        <div
          onMouseDown={startDrag}
          className={cn(
            'h-[52px] flex-shrink-0 flex items-end pb-2 pr-3 gap-2 cursor-default',
            isSidebarOpen ? 'pl-3' : 'pl-[78px]'
          )}
        >
          <button
            onClick={() => setIsSidebarOpen(!isSidebarOpen)}
            className={cn(
              'w-8 h-8 rounded-lg flex items-center justify-center transition-colors no-drag',
              'hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary',
              isSidebarOpen && 'text-theme-text-primary'
            )}
            title={isSidebarOpen ? 'Hide sidebar' : 'Show sidebar'}
          >
            {isSidebarOpen ? <PanelLeftClose className="w-4 h-4" /> : <PanelLeft className="w-4 h-4" />}
          </button>

          <div className="flex-1" />

          <button
            onClick={() => setIsSettingsOpen(true)}
            className="w-8 h-8 rounded-lg flex items-center justify-center hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary transition-colors no-drag"
            title="Settings"
          >
            <Settings className="w-4 h-4" />
          </button>
        </div>

        {/* Query Workspace */}
        <div className="flex-1 min-w-0 overflow-hidden">
          <QueryWorkspace
            isResultsExpanded={isResultsExpanded}
            onToggleResultsExpand={() => setIsResultsExpanded(!isResultsExpanded)}
          />
        </div>
      </div>

      {/* Dialogs */}
      <AddConnectionDialog
        isOpen={isAddConnectionOpen}
        onClose={() => setIsAddConnectionOpen(false)}
      />
      <EditConnectionDialog
        isOpen={editingConnection !== null}
        onClose={() => setEditingConnection(null)}
        connection={editingConnection?.config ?? null}
      />
      <SettingsDialog
        isOpen={isSettingsOpen}
        onClose={() => setIsSettingsOpen(false)}
      />
      <AboutDialog
        isOpen={isAboutOpen}
        onClose={() => setIsAboutOpen(false)}
      />

      {/* Table operation dialogs */}
      <CloneTableDialog
        isOpen={cloneTarget !== null}
        onClose={() => setCloneTarget(null)}
        connectionId={activeConnectionId || ''}
        schema={cloneTarget?.schema || ''}
        table={cloneTarget?.table || ''}
        type={cloneTarget?.type || 'table'}
        onSuccess={handleSchemaRefresh}
      />
      <ImportDataDialog
        isOpen={importTarget !== null}
        onClose={() => setImportTarget(null)}
        connectionId={activeConnectionId || ''}
        schema={importTarget?.schema || ''}
        table={importTarget?.table || ''}
        onSuccess={handleSchemaRefresh}
      />
      <ExportDataDialog
        isOpen={exportTarget !== null}
        onClose={() => setExportTarget(null)}
        connectionId={activeConnectionId || ''}
        schema={exportTarget?.schema || ''}
        table={exportTarget?.table || ''}
        type={exportTarget?.type || 'table'}
      />
    </div>
  );
}

export default App;
