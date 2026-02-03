import React from 'react';
import ReactDOM from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import App from './App';
import './index.css';

// Disable browser context menu globally to feel more like a native app
// Custom context menus in components will call e.preventDefault() and e.stopPropagation()
// before this handler runs, so they'll still work
document.addEventListener('contextmenu', (e) => {
  // Allow context menu in text inputs and textareas for copy/paste
  const target = e.target as HTMLElement;
  const isEditableElement =
    target.tagName === 'INPUT' ||
    target.tagName === 'TEXTAREA' ||
    target.isContentEditable ||
    target.closest('.monaco-editor');

  if (!isEditableElement) {
    e.preventDefault();
  }
});

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 1000 * 60 * 5, // 5 minutes
      retry: 1,
    },
  },
});

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <App />
    </QueryClientProvider>
  </React.StrictMode>,
);
