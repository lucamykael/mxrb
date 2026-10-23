import { fileURLToPath, URL } from 'node:url';
import { rmSync } from 'node:fs';
import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

// Keep this entry independent so adding an IDE panel does not invalidate the modeler's bundles.
export default defineConfig({
  base: './',
  plugins: [react(), {
    name: 'clean-studio-assets', apply: 'build',
    buildStart() {
      rmSync(fileURLToPath(new URL('../../lib/mxrb/web_ui/assets/studio', import.meta.url)), { recursive: true, force: true });
    }
  }],
  build: {
    outDir: '../../lib/mxrb/web_ui', emptyOutDir: false,
    rollupOptions: {
      input: { studio: fileURLToPath(new URL('./studio.html', import.meta.url)) },
      output: { entryFileNames: 'assets/studio/[name]-[hash].js', chunkFileNames: 'assets/studio/[name]-[hash].js',
        assetFileNames: 'assets/studio/[name]-[hash][extname]' }
    }
  }
});
