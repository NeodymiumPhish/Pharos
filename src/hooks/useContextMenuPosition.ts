import { useCallback, type RefObject } from 'react';

const VIEWPORT_PADDING = 8;

/**
 * Hook that provides a ref callback to automatically reposition
 * a fixed-position context menu so it stays within the viewport.
 *
 * Usage:
 *   const menuRef = useContextMenuPosition(contextMenu?.x, contextMenu?.y);
 *   <div ref={menuRef} style={{ left: contextMenu.x, top: contextMenu.y }} ... />
 *
 * The callback ref measures the element on mount and adjusts
 * left/top via inline style if it would overflow the viewport.
 *
 * An optional `forwardRef` can be provided to also store the element
 * (e.g. for outside-click detection with a useRef).
 */
export function useContextMenuPosition(
  requestedX: number | undefined,
  requestedY: number | undefined,
  forwardRef?: RefObject<HTMLDivElement | null>,
): (el: HTMLDivElement | null) => void {
  return useCallback(
    (el: HTMLDivElement | null) => {
      // Forward the element to an existing ref if provided
      if (forwardRef) {
        (forwardRef as { current: HTMLDivElement | null }).current = el;
      }

      if (!el || requestedX === undefined || requestedY === undefined) return;

      const rect = el.getBoundingClientRect();
      const vw = window.innerWidth;
      const vh = window.innerHeight;

      let x = requestedX;
      let y = requestedY;

      if (x + rect.width > vw - VIEWPORT_PADDING) {
        x = Math.max(VIEWPORT_PADDING, vw - rect.width - VIEWPORT_PADDING);
      }

      if (y + rect.height > vh - VIEWPORT_PADDING) {
        y = Math.max(VIEWPORT_PADDING, vh - rect.height - VIEWPORT_PADDING);
      }

      if (x !== requestedX || y !== requestedY) {
        el.style.left = `${x}px`;
        el.style.top = `${y}px`;
      }
    },
    [requestedX, requestedY, forwardRef],
  );
}
