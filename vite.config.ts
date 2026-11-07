import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath, URL } from 'node:url';

export default defineConfig({
  // No GitHub Pages o sistema fica em /geponto/ (definido pelo workflow de deploy).
  base: process.env.BASE_PATH || '/',
  plugins: [react()],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  server: { port: 3060, strictPort: true },
  preview: { port: 3060, strictPort: true },
});
