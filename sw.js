// Service worker de My Club: permite abrir la app sin conexión.
// Sube la versión al cambiar archivos para que los teléfonos reciban la actualización.
const CACHE = 'myclub-v15';
const FILES = ['./', './index.html', './config.js', './manifest.webmanifest', './icons/logo.png', './icons/escudo.png', './icons/icon-180.png', './icons/icon-192.png', './icons/icon-512.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(FILES)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

// Con internet siempre se usa la versión publicada; la caché es solo para trabajar sin conexión.
// Si primero se leyera la caché, un teléfono podría seguir apuntando a una base de datos antigua.
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET' || new URL(e.request.url).origin !== location.origin) return;
  e.respondWith(
    fetch(e.request).then(res => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); }
      return res;
    }).catch(() => caches.match(e.request, { ignoreSearch: true }).then(hit => hit || (e.request.mode === 'navigate' ? caches.match('./index.html') : Response.error())))
  );
});
