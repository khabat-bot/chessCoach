import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['icons/icon.svg', 'engine/worker.js'],
      manifest: {
        name: 'Chess Supercoach',
        short_name: 'Supercoach',
        description: 'Offline chess training with a local Stockfish engine.',
        theme_color: '#0b0f0e',
        background_color: '#0b0f0e',
        display: 'standalone',
        start_url: '/',
        icons: [
          { src: 'icons/icon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any' }
        ]
      },
      workbox: {
        globPatterns: ['**/*.{js,css,html,svg,png,ico,json,wasm}'],
        maximumFileSizeToCacheInBytes: 64 * 1024 * 1024,
        navigateFallback: '/index.html',
        navigateFallbackDenylist: [/^\/engine\//]
      }
    })
  ],
  server: { port: 5173 }
});
