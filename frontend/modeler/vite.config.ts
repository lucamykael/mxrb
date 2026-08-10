import { fileURLToPath, URL } from 'node:url';
import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

const apiPort = process.env.MXRB_UI_API_PORT ?? '4568';

export default defineConfig({
  base: './',
  plugins: [react()],
  build: {
    outDir: '../../lib/mxrb/web_ui',
    emptyOutDir: true,
    rollupOptions: {
      input: {
        domain: fileURLToPath(new URL('./domain.html', import.meta.url)),
        uml: fileURLToPath(new URL('./uml.html', import.meta.url))
      }
    }
  },
  server: {
    proxy: {
      '/api': `http://127.0.0.1:${apiPort}`
    }
  }
});
