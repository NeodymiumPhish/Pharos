import { cn } from '@/lib/cn';
import type { ReactNode, CSSProperties, MouseEventHandler } from 'react';

interface GlassPanelProps {
  children: ReactNode;
  className?: string;
  variant?: 'sidebar' | 'content' | 'toolbar' | 'surface';
  style?: CSSProperties;
  onMouseDown?: MouseEventHandler<HTMLDivElement>;
}

const variantStyles = {
  sidebar: 'bg-theme-bg-surface',
  content: 'bg-theme-bg-primary',
  toolbar: 'bg-theme-bg-elevated',
  surface: 'bg-theme-bg-surface',
};

export function GlassPanel({ children, className, variant = 'surface', style, onMouseDown }: GlassPanelProps) {
  return (
    <div
      className={cn(variantStyles[variant], className)}
      style={style}
      onMouseDown={onMouseDown}
    >
      {children}
    </div>
  );
}
