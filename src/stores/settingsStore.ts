import { create } from 'zustand';
import type { AppSettings, EditorSettings, QuerySettings, UISettings, ThemeMode, KeyboardSettings, KeyboardShortcut } from '@/lib/types';
import { DEFAULT_SETTINGS, DEFAULT_SHORTCUTS } from '@/lib/types';

interface SettingsState {
  settings: AppSettings;
  isLoaded: boolean;

  // Actions
  setSettings: (settings: AppSettings) => void;
  updateTheme: (theme: ThemeMode) => void;
  updateEditorSettings: (editor: Partial<EditorSettings>) => void;
  updateQuerySettings: (query: Partial<QuerySettings>) => void;
  updateUISettings: (ui: Partial<UISettings>) => void;
  updateKeyboardSettings: (keyboard: Partial<KeyboardSettings>) => void;
  updateShortcut: (id: string, shortcut: Partial<KeyboardShortcut>) => void;
  updateEmptyFolders: (folders: string[]) => void;
  resetShortcuts: () => void;
  resetToDefaults: () => void;

  // Getters
  getEffectiveTheme: () => 'light' | 'dark';
  getEmptyFolders: () => string[];
}

export const useSettingsStore = create<SettingsState>((set, get) => ({
  settings: DEFAULT_SETTINGS,
  isLoaded: false,

  setSettings: (settings) => {
    // Deep-merge with defaults so newly added fields get their default values
    const merged: AppSettings = {
      ...DEFAULT_SETTINGS,
      ...settings,
      editor: { ...DEFAULT_SETTINGS.editor, ...settings.editor },
      query: { ...DEFAULT_SETTINGS.query, ...settings.query },
      ui: { ...DEFAULT_SETTINGS.ui, ...settings.ui },
      keyboard: {
        ...DEFAULT_SETTINGS.keyboard,
        ...settings.keyboard,
        shortcuts: { ...DEFAULT_SETTINGS.keyboard.shortcuts, ...settings.keyboard?.shortcuts },
      },
    };
    set({ settings: merged, isLoaded: true });
  },

  updateTheme: (theme) => {
    set((state) => ({
      settings: {
        ...state.settings,
        theme,
      },
    }));
  },

  updateEditorSettings: (editor) => {
    set((state) => ({
      settings: {
        ...state.settings,
        editor: {
          ...state.settings.editor,
          ...editor,
        },
      },
    }));
  },

  updateQuerySettings: (query) => {
    set((state) => ({
      settings: {
        ...state.settings,
        query: {
          ...state.settings.query,
          ...query,
        },
      },
    }));
  },

  updateUISettings: (ui) => {
    set((state) => ({
      settings: {
        ...state.settings,
        ui: {
          ...state.settings.ui,
          ...ui,
        },
      },
    }));
  },

  updateKeyboardSettings: (keyboard) => {
    set((state) => ({
      settings: {
        ...state.settings,
        keyboard: {
          ...state.settings.keyboard,
          ...keyboard,
        },
      },
    }));
  },

  updateShortcut: (id, shortcut) => {
    set((state) => ({
      settings: {
        ...state.settings,
        keyboard: {
          ...state.settings.keyboard,
          shortcuts: {
            ...state.settings.keyboard.shortcuts,
            [id]: {
              ...state.settings.keyboard.shortcuts[id],
              ...shortcut,
            },
          },
        },
      },
    }));
  },

  resetShortcuts: () => {
    set((state) => ({
      settings: {
        ...state.settings,
        keyboard: {
          shortcuts: DEFAULT_SHORTCUTS,
        },
      },
    }));
  },

  updateEmptyFolders: (folders) => {
    set((state) => ({
      settings: {
        ...state.settings,
        emptyFolders: folders,
      },
    }));
  },

  resetToDefaults: () => {
    set({ settings: DEFAULT_SETTINGS });
  },

  getEffectiveTheme: () => {
    const { settings } = get();
    if (settings.theme === 'auto') {
      // Check system preference
      if (typeof window !== 'undefined' && window.matchMedia) {
        return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
      }
      return 'dark'; // Default to dark if can't detect
    }
    return settings.theme;
  },

  getEmptyFolders: () => {
    return get().settings.emptyFolders ?? [];
  },
}));
