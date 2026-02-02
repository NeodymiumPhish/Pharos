import { useEffect, useRef } from 'react';
import { useSettingsStore } from '@/stores/settingsStore';
import { DEFAULT_SHORTCUTS } from '@/lib/types';

type ShortcutHandler = () => void;

// Custom event type for Monaco-originated shortcuts
export interface AppShortcutEvent extends CustomEvent {
  detail: { id: string };
}

/**
 * Hook to handle keyboard shortcuts throughout the application.
 *
 * This hook listens for two types of events:
 * 1. Custom 'app-shortcut' events emitted by Monaco editor
 * 2. Regular keyboard events for non-Monaco contexts
 *
 * Monaco captures keyboard events internally, so we register shortcuts
 * in Monaco that emit custom events, which this hook then handles.
 */
export function useKeyboardShortcuts(handlers: Record<string, ShortcutHandler>) {
  const shortcuts = useSettingsStore(
    (state) => state.settings.keyboard?.shortcuts ?? DEFAULT_SHORTCUTS
  );

  // Use ref to always have access to latest handlers without re-creating listener
  const handlersRef = useRef(handlers);
  handlersRef.current = handlers;

  useEffect(() => {
    // Handler for custom events from Monaco
    const handleAppShortcut = (e: Event) => {
      const customEvent = e as AppShortcutEvent;
      const handler = handlersRef.current[customEvent.detail.id];
      if (handler) {
        handler();
      }
    };

    // Handler for keyboard events (when NOT in Monaco)
    const handleKeyDown = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement;

      // Skip if in Monaco editor - Monaco handles shortcuts via custom event
      if (target.closest('.monaco-editor')) {
        return;
      }

      // Skip standard inputs except for Escape
      if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA') {
        if (e.key !== 'Escape') {
          return;
        }
      }

      const isMod = e.metaKey || e.ctrlKey;
      const isShift = e.shiftKey;
      const isAlt = e.altKey;
      const key = e.key;

      for (const [shortcutId, shortcut] of Object.entries(shortcuts)) {
        const handler = handlersRef.current[shortcutId];
        if (!handler) continue;

        const needsMod = shortcut.modifiers.includes('cmd');
        const needsShift = shortcut.modifiers.includes('shift');
        const needsAlt = shortcut.modifiers.includes('alt');

        // Match key (case-insensitive for letters, exact for special keys)
        const keyMatches =
          key.toLowerCase() === shortcut.key.toLowerCase() || key === shortcut.key;

        if (keyMatches && isMod === needsMod && isShift === needsShift && isAlt === needsAlt) {
          e.preventDefault();
          e.stopPropagation();
          handler();
          return;
        }
      }
    };

    // Listen for custom events from Monaco
    window.addEventListener('app-shortcut', handleAppShortcut);
    // Listen for keyboard events with capture phase for non-Monaco contexts
    window.addEventListener('keydown', handleKeyDown, true);

    return () => {
      window.removeEventListener('app-shortcut', handleAppShortcut);
      window.removeEventListener('keydown', handleKeyDown, true);
    };
  }, [shortcuts]);
}

/**
 * Utility to format a shortcut for display
 */
export function formatShortcut(shortcut: { key: string; modifiers: string[] }): string {
  const parts: string[] = [];

  if (shortcut.modifiers.includes('cmd')) {
    parts.push('⌘');
  }
  if (shortcut.modifiers.includes('shift')) {
    parts.push('⇧');
  }
  if (shortcut.modifiers.includes('alt')) {
    parts.push('⌥');
  }

  // Format special keys
  let keyDisplay = shortcut.key;
  switch (shortcut.key.toLowerCase()) {
    case 'enter':
      keyDisplay = '↩';
      break;
    case 'escape':
      keyDisplay = 'Esc';
      break;
    case 'arrowup':
      keyDisplay = '↑';
      break;
    case 'arrowdown':
      keyDisplay = '↓';
      break;
    case 'arrowleft':
      keyDisplay = '←';
      break;
    case 'arrowright':
      keyDisplay = '→';
      break;
    case ' ':
      keyDisplay = 'Space';
      break;
    case 'backspace':
      keyDisplay = '⌫';
      break;
    case 'delete':
      keyDisplay = '⌦';
      break;
    case 'tab':
      keyDisplay = '⇥';
      break;
    case ',':
      keyDisplay = ',';
      break;
    default:
      keyDisplay = shortcut.key.toUpperCase();
  }

  parts.push(keyDisplay);
  return parts.join('');
}
