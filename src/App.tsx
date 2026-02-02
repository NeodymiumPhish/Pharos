import { useState, useEffect } from 'react';
import { listen } from '@tauri-apps/api/event';
import { ServerRail } from '@/components/layout/ServerRail';
import { DatabaseNavigator } from '@/components/layout/DatabaseNavigator';
import { QueryWorkspace } from '@/components/layout/QueryWorkspace';
import { StatusBar } from '@/components/ui/StatusBar';
import { AddConnectionDialog } from '@/components/dialogs/AddConnectionDialog';
import { SettingsDialog } from '@/components/dialogs/SettingsDialog';
import { AboutDialog } from '@/components/dialogs/AboutDialog';
import { useWindowDrag } from '@/hooks/useWindowDrag';
import { useConnectionStore } from '@/stores/connectionStore';
import { useSettingsStore } from '@/stores/settingsStore';
import { useTheme } from '@/hooks/useTheme';
import * as tauri from '@/lib/tauri';

function App() {
  const [sidebarWidth, setSidebarWidth] = useState(280);
  const [isAddConnectionOpen, setIsAddConnectionOpen] = useState(false);
  const [isSettingsOpen, setIsSettingsOpen] = useState(false);
  const [isAboutOpen, setIsAboutOpen] = useState(false);
  const [schemaRefreshTrigger, setSchemaRefreshTrigger] = useState(0);
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

  return (
    <div className="h-screen w-screen flex flex-col overflow-hidden bg-theme-bg-surface">
      {/* Traffic lights area - unified top bar */}
      <div
        onMouseDown={startDrag}
        className="h-12 flex-shrink-0 cursor-default bg-theme-bg-elevated border-b border-theme-border-primary"
      />

      {/* Main content area */}
      <div className="flex-1 flex overflow-hidden">
        {/* Server Rail */}
        <ServerRail
          onAddConnection={() => setIsAddConnectionOpen(true)}
          onSchemaRefresh={handleSchemaRefresh}
        />

        {/* Database Navigator - hidden when results are expanded */}
        {!isResultsExpanded && (
          <DatabaseNavigator
            width={sidebarWidth}
            onWidthChange={setSidebarWidth}
            minWidth={200}
            maxWidth={500}
            refreshTrigger={schemaRefreshTrigger}
          />
        )}

        {/* Query Workspace */}
        <div className="flex-1 min-w-0 overflow-hidden">
          <QueryWorkspace
            isResultsExpanded={isResultsExpanded}
            onToggleResultsExpand={() => setIsResultsExpanded(!isResultsExpanded)}
          />
        </div>
      </div>

      {/* Status Bar */}
      <StatusBar />

      {/* Dialogs */}
      <AddConnectionDialog
        isOpen={isAddConnectionOpen}
        onClose={() => setIsAddConnectionOpen(false)}
      />
      <SettingsDialog
        isOpen={isSettingsOpen}
        onClose={() => setIsSettingsOpen(false)}
      />
      <AboutDialog
        isOpen={isAboutOpen}
        onClose={() => setIsAboutOpen(false)}
      />
    </div>
  );
}

export default App;
