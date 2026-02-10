import { create } from 'zustand';
import * as tauri from '@/lib/tauri';
import type { QueryHistoryEntry } from '@/lib/types';

const PAGE_SIZE = 100;

interface QueryHistoryState {
  entries: QueryHistoryEntry[];
  isLoading: boolean;
  hasMore: boolean;
  search: string;

  // Actions
  loadHistory: (connectionId?: string) => Promise<void>;
  loadMore: (connectionId?: string) => Promise<void>;
  setSearch: (search: string) => void;
  deleteEntry: (id: string) => Promise<void>;
  clearHistory: () => Promise<void>;
  prependEntry: (entry: QueryHistoryEntry) => void;
  updateEntry: (id: string, updates: Partial<QueryHistoryEntry>) => void;
}

export const useQueryHistoryStore = create<QueryHistoryState>((set, get) => ({
  entries: [],
  isLoading: false,
  hasMore: true,
  search: '',

  loadHistory: async (connectionId?: string) => {
    set({ isLoading: true });
    try {
      const { search } = get();
      const entries = await tauri.loadQueryHistory(
        connectionId,
        search || undefined,
        PAGE_SIZE,
        0
      );
      set({
        entries,
        hasMore: entries.length >= PAGE_SIZE,
        isLoading: false,
      });
    } catch (err) {
      console.error('Failed to load query history:', err);
      set({ isLoading: false });
    }
  },

  loadMore: async (connectionId?: string) => {
    const { entries, hasMore, isLoading, search } = get();
    if (!hasMore || isLoading) return;

    set({ isLoading: true });
    try {
      const moreEntries = await tauri.loadQueryHistory(
        connectionId,
        search || undefined,
        PAGE_SIZE,
        entries.length
      );
      set({
        entries: [...entries, ...moreEntries],
        hasMore: moreEntries.length >= PAGE_SIZE,
        isLoading: false,
      });
    } catch (err) {
      console.error('Failed to load more history:', err);
      set({ isLoading: false });
    }
  },

  setSearch: (search: string) => {
    set({ search });
  },

  deleteEntry: async (id: string) => {
    try {
      await tauri.deleteQueryHistoryEntry(id);
      set({ entries: get().entries.filter((e) => e.id !== id) });
    } catch (err) {
      console.error('Failed to delete history entry:', err);
    }
  },

  clearHistory: async () => {
    try {
      await tauri.clearQueryHistory();
      set({ entries: [], hasMore: false });
    } catch (err) {
      console.error('Failed to clear query history:', err);
    }
  },

  prependEntry: (entry: QueryHistoryEntry) => {
    set({ entries: [entry, ...get().entries] });
  },

  updateEntry: (id: string, updates: Partial<QueryHistoryEntry>) => {
    set({
      entries: get().entries.map((e) =>
        e.id === id ? { ...e, ...updates } : e
      ),
    });
  },
}));
