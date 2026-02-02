import { getCurrentWindow } from '@tauri-apps/api/window';
import type { MouseEvent } from 'react';

export function useWindowDrag() {
  const startDrag = (e: MouseEvent<HTMLElement>) => {
    // Only start drag on left mouse button and if not clicking a button/input
    if (e.button !== 0) return;

    const target = e.target as HTMLElement;
    if (
      target.tagName === 'BUTTON' ||
      target.tagName === 'INPUT' ||
      target.tagName === 'TEXTAREA' ||
      target.closest('button') ||
      target.closest('input') ||
      target.closest('.no-drag')
    ) {
      return;
    }

    e.preventDefault();
    getCurrentWindow().startDragging();
  };

  return { startDrag };
}
