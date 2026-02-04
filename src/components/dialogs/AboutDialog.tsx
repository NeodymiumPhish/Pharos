import { X } from 'lucide-react';
import pharosIcon from '@/assets/pharos-icon.png';

interface AboutDialogProps {
  isOpen: boolean;
  onClose: () => void;
}

export function AboutDialog({ isOpen, onClose }: AboutDialogProps) {
  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* Backdrop */}
      <div className="absolute inset-0 bg-black/50" onClick={onClose} />

      {/* Dialog */}
      <div className="relative w-72 rounded-lg border border-theme-border-secondary bg-theme-bg-elevated shadow-2xl">
        <button
          onClick={onClose}
          className="absolute top-2 right-2 p-1 rounded hover:bg-theme-bg-hover text-theme-text-tertiary hover:text-theme-text-primary"
        >
          <X className="w-4 h-4" />
        </button>

        <div className="flex flex-col items-center py-8 px-6">
          {/* App icon */}
          <img
            src={pharosIcon}
            alt="Pharos"
            className="w-24 h-24 mb-4"
          />

          {/* App name */}
          <h1 className="text-xl font-semibold text-theme-text-primary">Pharos</h1>

          {/* Version */}
          <p className="text-sm text-theme-text-tertiary mt-1">Version 0.0.0-dev</p>

          {/* Description */}
          <p className="text-xs text-theme-text-muted mt-4 text-center">
            A modern PostgreSQL client
          </p>
        </div>
      </div>
    </div>
  );
}
