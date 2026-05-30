// Event Timer — service worker. Caches the app shell so it runs offline at events.
const CACHE = 'event-timer-v5';
const ASSETS = [
  './',
  './index.html',
  './control.html',
  './display.html',
  './common.js',
  './manifest.webmanifest',
  './icons/icon-192.png',
  './icons/icon-512.png'
];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE).then(c => c.addAll(ASSETS)).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// Stale-while-revalidate: serve from cache instantly (offline-capable), then
// refresh the cache in the background so the next load picks up any update.
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  e.respondWith(
    caches.open(CACHE).then(cache =>
      cache.match(e.request).then(cached => {
        const network = fetch(e.request).then(resp => {
          try { cache.put(e.request, resp.clone()); } catch (_) {}
          return resp;
        }).catch(() => cached);
        return cached || network;
      })
    )
  );
});
