import { useEffect } from 'react';
import { useSettingsStore } from '@/stores/settingsStore';

export function useTheme() {
  const theme = useSettingsStore((state) => state.settings.theme);
  const getEffectiveTheme = useSettingsStore((state) => state.getEffectiveTheme);

  useEffect(() => {
    const applyTheme = () => {
      const effectiveTheme = getEffectiveTheme();
      document.documentElement.setAttribute('data-theme', effectiveTheme);
    };

    applyTheme();

    // Listen for system theme changes when in auto mode
    if (theme === 'auto') {
      const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
      const handleChange = () => applyTheme();
      mediaQuery.addEventListener('change', handleChange);
      return () => mediaQuery.removeEventListener('change', handleChange);
    }
  }, [theme, getEffectiveTheme]);

  return getEffectiveTheme();
}
