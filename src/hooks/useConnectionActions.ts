import { useCallback } from 'react';
import { ask } from '@tauri-apps/plugin-dialog';
import { useConnectionStore } from '@/stores/connectionStore';
import * as tauri from '@/lib/tauri';
import type { Connection } from '@/lib/types';

export function useConnectionActions(onSchemaRefresh?: (connectionId: string) => void) {
  const updateConnectionStatus = useConnectionStore((state) => state.updateConnectionStatus);
  const addConnection = useConnectionStore((state) => state.addConnection);
  const removeConnection = useConnectionStore((state) => state.removeConnection);

  const handleConnect = useCallback(
    async (connection: Connection) => {
      updateConnectionStatus(connection.config.id, 'connecting');

      try {
        const result = await tauri.connectPostgres(connection.config.id);

        if (result.status === 'connected') {
          updateConnectionStatus(connection.config.id, 'connected', undefined, result.latency_ms);
          onSchemaRefresh?.(connection.config.id);
        } else if (result.status === 'error') {
          updateConnectionStatus(connection.config.id, 'error', result.error || 'Connection failed');
        } else {
          updateConnectionStatus(connection.config.id, result.status);
        }
      } catch (err) {
        const errorMessage = err instanceof Error ? err.message : String(err);
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

      if (!confirmed) return;

      if (wasConnected) {
        try {
          await tauri.disconnectPostgres(connectionId);
        } catch (err) {
          console.error('Disconnect error:', err);
        }
      }

      try {
        await tauri.deleteConnection(connectionId);
        removeConnection(connectionId);
      } catch (err) {
        console.error('Delete error:', err);
      }
    },
    [removeConnection]
  );

  const handleDuplicate = useCallback(
    async (connection: Connection) => {
      const newConfig = {
        ...connection.config,
        id: crypto.randomUUID(),
        name: `${connection.config.name} (copy)`,
        password: '',
      };

      try {
        await tauri.saveConnection(newConfig);
        addConnection(newConfig);
      } catch (err) {
        console.error('Failed to duplicate connection:', err);
      }
    },
    [addConnection]
  );

  return { handleConnect, handleDisconnect, handleRefresh, handleDelete, handleDuplicate };
}
