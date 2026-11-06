// Service worker de My Club: guarda todo en caché para funcionar sin conexión.
// Sube la versión al cambiar archivos para que los teléfonos reciban la actualización.
const CACHE = 'myclub-v5';
const FILES = ['./', './index.html', './config.js', './manifest.webmanifest', './icons/logo.png', './icons/escudo.png', './icons/icon-180.png', './icons/icon-192.png', './icons/icon-512.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(FILES)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  e.respondWith(
    caches.match(e.request, { ignoreSearch: true }).then(hit => hit || fetch(e.request).catch(() => {
      if (e.request.mode === 'navigate') return caches.match('./index.html');
      return Response.error();
    }))
  );
});
