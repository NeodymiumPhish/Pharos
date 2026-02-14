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
            stripe: 'var(--bg-stripe)',
            sidebar: 'var(--bg-sidebar)',
            toolbar: 'var(--bg-toolbar)',
          },
          border: {
            primary: 'var(--border-primary)',
            secondary: 'var(--border-secondary)',
            subtle: 'var(--border-subtle)',
          },
          text: {
            primary: 'var(--text-primary)',
            secondary: 'var(--text-secondary)',
            tertiary: 'var(--text-tertiary)',
            muted: 'var(--text-muted)',
          },
          accent: {
            green: 'var(--accent-green)',
            'green-hover': 'var(--accent-green-hover)',
          },
        },
        // Status indicator colors
        status: {
          connected: '#22c55e',
          disconnected: '#ef4444',
          connecting: '#f59e0b',
        },
      },
      fontFamily: {
        sans: ['-apple-system', 'BlinkMacSystemFont', 'Segoe UI', 'Roboto', 'sans-serif'],
        mono: ['SF Mono', 'Menlo', 'Monaco', 'Consolas', 'monospace'],
      },
    },
  },
  plugins: [],
}
