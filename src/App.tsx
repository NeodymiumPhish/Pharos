import { useState, useEffect } from 'react';
import { listen } from '@tauri-apps/api/event';
import { Sidebar } from '@/components/layout/Sidebar';
import { QueryWorkspace } from '@/components/layout/QueryWorkspace';
import { StatusBar } from '@/components/ui/StatusBar';
import { AddConnectionDialog } from '@/components/dialogs/AddConnectionDialog';
import { EditConnectionDialog } from '@/components/dialogs/EditConnectionDialog';
import { CloneTableDialog } from '@/components/dialogs/CloneTableDialog';
import { ImportDataDialog } from '@/components/dialogs/ImportDataDialog';
import { ExportDataDialog } from '@/components/dialogs/ExportDataDialog';
import { SettingsDialog } from '@/components/dialogs/SettingsDialog';
import { AboutDialog } from '@/components/dialogs/AboutDialog';
import { useWindowDrag } from '@/hooks/useWindowDrag';
import { useConnectionStore } from '@/stores/connectionStore';
import { useEditorStore } from '@/stores/editorStore';
import type { Connection } from '@/lib/types';
import { useSettingsStore } from '@/stores/settingsStore';
import { useTheme } from '@/hooks/useTheme';
import * as tauri from '@/lib/tauri';

function App() {
  const [sidebarWidth, setSidebarWidth] = useState(260);
  const [isSidebarCollapsed, setIsSidebarCollapsed] = useState(false);
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
  const { startDrag } = useWindowDrag();
  const setConnections = useConnectionStore((state) => state.setConnections);
  const setSettings = useSettingsStore((state) => state.setSettings);

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
    <div className="h-screen w-screen flex overflow-hidden bg-transparent text-theme-text-primary font-sans selection:bg-theme-accent/30 selection:text-theme-text-primary">
      {/* Sidebar - Glass Effect */}
      {!isResultsExpanded && (
        <Sidebar
          width={sidebarWidth}
          onWidthChange={setSidebarWidth}
          isCollapsed={isSidebarCollapsed}
          onToggleCollapse={() => setIsSidebarCollapsed(!isSidebarCollapsed)}
          onAddConnection={() => setIsAddConnectionOpen(true)}
          onEditConnection={(connection) => setEditingConnection(connection)}
          schemaRefreshTrigger={schemaRefreshTrigger}
          onCloneTable={(schema, table, type) => setCloneTarget({ schema, table, type })}
          onImportData={(schema, table) => setImportTarget({ schema, table })}
          onExportData={(schema, table, type) => setExportTarget({ schema, table, type })}
          onViewRows={handleViewRows}
        />
      )}

      {/* Main Content Area - Solid Background */}
      <div className="flex-1 flex flex-col min-w-0 bg-theme-bg-primary relative shadow-2xl border-l border-theme-border-primary/50">

        {/* Top Bar / Drag Region (matches sidebar header height) */}
        <div
          onMouseDown={startDrag}
          data-tauri-drag-region
          className="h-[38px] flex-shrink-0 flex items-center px-4 border-b border-theme-border-primary bg-theme-bg-surface select-none"
        >
          {/* Add tabs or toolbar content here later */}
        </div>

        {/* Query Workspace */}
        <div className="flex-1 overflow-hidden relative">
          <QueryWorkspace
            isResultsExpanded={isResultsExpanded}
            onToggleResultsExpand={() => setIsResultsExpanded(!isResultsExpanded)}
          />
        </div>

        {/* Status Bar */}
        <StatusBar />
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
