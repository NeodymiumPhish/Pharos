import { create } from 'zustand';
import { invoke } from '@tauri-apps/api/core';
import type { SavedQuery, CreateSavedQuery, UpdateSavedQuery } from '@/lib/types';

interface SavedQueryState {
  queries: SavedQuery[];
  isLoading: boolean;
  error: string | null;
  emptyFolders: string[]; // Explicitly created folders that have no queries

  // Actions
  loadQueries: () => Promise<void>;
  createQuery: (query: CreateSavedQuery) => Promise<SavedQuery>;
  updateQuery: (update: UpdateSavedQuery) => Promise<SavedQuery | null>;
  deleteQuery: (id: string) => Promise<boolean>;

  // Empty folder actions
  setEmptyFolders: (folders: string[]) => void;
  addEmptyFolder: (name: string) => void;
  removeEmptyFolder: (name: string) => void;
  renameEmptyFolder: (oldName: string, newName: string) => void;

  // Getters
  getQuery: (id: string) => SavedQuery | undefined;
  getQueriesByFolder: (folder: string | null) => SavedQuery[];
  getFolders: () => string[];
  getAllFolders: () => string[]; // Includes both query-derived and empty folders
}

export const useSavedQueryStore = create<SavedQueryState>((set, get) => ({
  queries: [],
  isLoading: false,
  error: null,
  emptyFolders: [],

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

  setEmptyFolders: (folders) => {
    set({ emptyFolders: folders });
  },

  addEmptyFolder: (name) => {
    const trimmed = name.trim();
    if (!trimmed) return;

    set((state) => {
      // Check if folder already exists (in queries or empty folders)
      const existingQueryFolders = new Set(state.queries.map((q) => q.folder).filter(Boolean));
      if (existingQueryFolders.has(trimmed) || state.emptyFolders.includes(trimmed)) {
        return state; // Folder already exists
      }
      return {
        emptyFolders: [...state.emptyFolders, trimmed].sort(),
      };
    });
  },

  removeEmptyFolder: (name) => {
    set((state) => ({
      emptyFolders: state.emptyFolders.filter((f) => f !== name),
    }));
  },

  renameEmptyFolder: (oldName, newName) => {
    const trimmed = newName.trim();
    if (!trimmed || oldName === trimmed) return;

    set((state) => {
      // Check if new name already exists
      const existingQueryFolders = new Set(state.queries.map((q) => q.folder).filter(Boolean));
      if (existingQueryFolders.has(trimmed) || state.emptyFolders.includes(trimmed)) {
        return state; // New name already exists
      }
      return {
        emptyFolders: state.emptyFolders
          .map((f) => (f === oldName ? trimmed : f))
          .sort(),
      };
    });
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

  getAllFolders: () => {
    const { queries, emptyFolders } = get();
    const folders = new Set<string>();

    // Add folders from queries
    queries.forEach((q) => {
      if (q.folder) {
        folders.add(q.folder);
      }
    });

    // Add empty folders
    emptyFolders.forEach((f) => folders.add(f));

    return Array.from(folders).sort();
  },
}));
