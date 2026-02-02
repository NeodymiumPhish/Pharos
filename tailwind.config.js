/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        // Theme-aware colors using CSS variables
        theme: {
          bg: {
            primary: 'var(--bg-primary)',
            surface: 'var(--bg-surface)',
            elevated: 'var(--bg-elevated)',
            hover: 'var(--bg-hover)',
            active: 'var(--bg-active)',
          },
          border: {
            primary: 'var(--border-primary)',
            secondary: 'var(--border-secondary)',
          },
          text: {
            primary: 'var(--text-primary)',
            secondary: 'var(--text-secondary)',
            tertiary: 'var(--text-tertiary)',
            muted: 'var(--text-muted)',
          },
        },
        // Glass panel colors with transparency
        glass: {
          light: 'rgba(255, 255, 255, 0.1)',
          DEFAULT: 'rgba(255, 255, 255, 0.15)',
          dark: 'rgba(0, 0, 0, 0.2)',
          darker: 'rgba(0, 0, 0, 0.4)',
        },
        // Status indicator colors
        status: {
          connected: '#22c55e',
          disconnected: '#ef4444',
          connecting: '#f59e0b',
        },
      },
      backdropBlur: {
        glass: '20px',
      },
      fontFamily: {
        sans: ['-apple-system', 'BlinkMacSystemFont', 'Segoe UI', 'Roboto', 'sans-serif'],
        mono: ['SF Mono', 'Menlo', 'Monaco', 'Consolas', 'monospace'],
      },
    },
  },
  plugins: [],
}
