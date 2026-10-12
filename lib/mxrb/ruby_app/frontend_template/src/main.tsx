import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './app/App';
import './styles/index.css';
// Widget package styles come before the theme, which may override them.
import './generated/platform/widgets/widgets.css';
import './generated/platform/theme-cache/web/theme.compiled.css';

const root = document.getElementById('root');
if (!root) throw new Error('Application root element is missing');

createRoot(root).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
