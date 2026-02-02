import { create } from 'zustand';
import { invoke } from '@tauri-apps/api/core';
import type { SavedQuery, CreateSavedQuery, UpdateSavedQuery } from '@/lib/types';

interface SavedQueryState {
  queries: SavedQuery[];
  isLoading: boolean;
  error: string | null;

  // Actions
  loadQueries: () => Promise<void>;
  createQuery: (query: CreateSavedQuery) => Promise<SavedQuery>;
  updateQuery: (update: UpdateSavedQuery) => Promise<SavedQuery | null>;
  deleteQuery: (id: string) => Promise<boolean>;

  // Getters
  getQuery: (id: string) => SavedQuery | undefined;
  getQueriesByFolder: (folder: string | null) => SavedQuery[];
  getFolders: () => string[];
}

export const useSavedQueryStore = create<SavedQueryState>((set, get) => ({
  queries: [],
  isLoading: false,
  error: null,

  loadQueries: async () => {
    set({ isLoading: true, error: null });
    try {
      const queries = await invoke<SavedQuery[]>('load_saved_queries');
      set({ queries, isLoading: false });
    } catch (error) {
      set({ error: String(error), isLoading: false });
    }
  },

  createQuery: async (query) => {
    const result = await invoke<SavedQuery>('create_saved_query', { query });
    set((state) => ({
      queries: [...state.queries, result].sort((a, b) => a.name.localeCompare(b.name)),
    }));
    return result;
  },

  updateQuery: async (update) => {
    const result = await invoke<SavedQuery | null>('update_saved_query', { update });
    if (result) {
      set((state) => ({
        queries: state.queries
          .map((q) => (q.id === result.id ? result : q))
          .sort((a, b) => a.name.localeCompare(b.name)),
      }));
    }
    return result;
  },

  deleteQuery: async (id) => {
    const result = await invoke<boolean>('delete_saved_query', { queryId: id });
    if (result) {
      set((state) => ({
        queries: state.queries.filter((q) => q.id !== id),
      }));
    }
    return result;
  },

  getQuery: (id) => {
    return get().queries.find((q) => q.id === id);
  },

  getQueriesByFolder: (folder) => {
    return get().queries.filter((q) =>
      folder === null ? !q.folder : q.folder === folder
    );
  },

  getFolders: () => {
    const folders = new Set<string>();
    get().queries.forEach((q) => {
      if (q.folder) {
        folders.add(q.folder);
      }
    });
    return Array.from(folders).sort();
  },
}));
