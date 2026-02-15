import { useEffect } from 'react';
import { useSettingsStore } from '@/stores/settingsStore';

export function useTheme() {
  const theme = useSettingsStore((state) => state.settings.theme);
  const accentColor = useSettingsStore((state) => state.settings.ui.accentColor);
  const getEffectiveTheme = useSettingsStore((state) => state.getEffectiveTheme);

  useEffect(() => {
    const applyTheme = () => {
      const effectiveTheme = getEffectiveTheme();
      document.documentElement.setAttribute('data-theme', effectiveTheme);
      // Apply accent color
      if (accentColor) {
        document.documentElement.style.setProperty('--accent-color', accentColor);
      }
    };

    applyTheme();

    // Listen for system theme changes when in auto mode
    if (theme === 'auto') {
      const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
      const handleChange = () => applyTheme();
      mediaQuery.addEventListener('change', handleChange);
      return () => mediaQuery.removeEventListener('change', handleChange);
    }
  }, [theme, accentColor, getEffectiveTheme]);

  return getEffectiveTheme();
}
