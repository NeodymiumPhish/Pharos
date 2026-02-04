import { create } from 'zustand';
import type { Connection, ConnectionConfig, ConnectionStatus } from '@/lib/types';

interface ConnectionState {
  // All saved connections (using Record for better Zustand compatibility)
  connections: Record<string, Connection>;

  // Connection order (array of connection IDs in display order)
  connectionOrder: string[];

  // Currently active/selected connection ID
  activeConnectionId: string | null;

  // Selected schema per connection (connectionId -> schemaName)
  selectedSchemas: Record<string, string | null>;

  // Actions
  setConnections: (configs: ConnectionConfig[]) => void;
  addConnection: (config: ConnectionConfig) => void;
  updateConnection: (config: ConnectionConfig) => void;
  removeConnection: (id: string) => void;
  updateConnectionStatus: (id: string, status: ConnectionStatus, error?: string, latency?: number) => void;
  setActiveConnection: (id: string | null) => void;
  setSelectedSchema: (connectionId: string, schema: string | null) => void;
  reorderConnections: (connectionIds: string[]) => void;

  // Getters
  getConnection: (id: string) => Connection | undefined;
  getActiveConnection: () => Connection | undefined;
  getConnectedConnections: () => Connection[];
  getConnectionsList: () => Connection[];
  getOrderedConnections: () => Connection[];
  getSelectedSchema: (connectionId: string) => string | null;
  getActiveSelectedSchema: () => string | null;
}

export const useConnectionStore = create<ConnectionState>((set, get) => ({
  connections: {},
  connectionOrder: [],
  activeConnectionId: null,
  selectedSchemas: {},

  setConnections: (configs) => {
    const connections: Record<string, Connection> = {};
    const connectionOrder: string[] = [];
    configs.forEach((config) => {
      connections[config.id] = {
        config,
        status: 'disconnected',
      };
      connectionOrder.push(config.id);
    });
    set({ connections, connectionOrder });
  },

  addConnection: (config) => {
    set((state) => ({
      connections: {
        ...state.connections,
        [config.id]: {
          config,
          status: 'disconnected',
        },
      },
      connectionOrder: [...state.connectionOrder, config.id],
    }));
  },

  updateConnection: (config) => {
    set((state) => {
      const existing = state.connections[config.id];
      if (!existing) return state;
      return {
        connections: {
          ...state.connections,
          [config.id]: {
            ...existing,
            config,
          },
        },
      };
    });
  },

  removeConnection: (id) => {
    set((state) => {
      const { [id]: removed, ...rest } = state.connections;
      return {
        connections: rest,
        connectionOrder: state.connectionOrder.filter((cid) => cid !== id),
        activeConnectionId: state.activeConnectionId === id ? null : state.activeConnectionId,
      };
    });
  },

  updateConnectionStatus: (id, status, error, latency) => {
    set((state) => {
      const connection = state.connections[id];
      if (!connection) return state;
      return {
        connections: {
          ...state.connections,
          [id]: {
            ...connection,
            status,
            error,
            latency,
          },
        },
      };
    });
  },

  setActiveConnection: (id) => {
    set({ activeConnectionId: id });
  },

  setSelectedSchema: (connectionId, schema) => {
    set((state) => ({
      selectedSchemas: {
        ...state.selectedSchemas,
        [connectionId]: schema,
      },
    }));
  },

  reorderConnections: (connectionIds) => {
    set({ connectionOrder: connectionIds });
  },

  getConnection: (id) => {
    return get().connections[id];
  },

  getActiveConnection: () => {
    const { connections, activeConnectionId } = get();
    if (!activeConnectionId) return undefined;
    return connections[activeConnectionId];
  },

  getConnectedConnections: () => {
    const { connections } = get();
    return Object.values(connections).filter((c) => c.status === 'connected');
  },

  getConnectionsList: () => {
    return Object.values(get().connections);
  },

  getOrderedConnections: () => {
    const { connections, connectionOrder } = get();
    return connectionOrder
      .map((id) => connections[id])
      .filter((c): c is Connection => c !== undefined);
  },

  getSelectedSchema: (connectionId) => {
    return get().selectedSchemas[connectionId] ?? null;
  },

  getActiveSelectedSchema: () => {
    const { activeConnectionId, selectedSchemas } = get();
    if (!activeConnectionId) return null;
    return selectedSchemas[activeConnectionId] ?? null;
  },
}));
