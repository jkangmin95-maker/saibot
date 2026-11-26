const CACHE_NAME = 'urisai-pwa-v11-6';
const ASSETS = ['./manifest.json', './icon-192.png', './icon-512.png', './og.png', './app.css'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(ASSETS)).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;

  const isHtml =
    event.request.mode === 'navigate' ||
    url.pathname.endsWith('/') ||
    url.pathname.endsWith('/index.html') ||
    /(index|quiz)\.html$/i.test(url.pathname);

  // HTML: ask GitHub Pages to revalidate (it sends max-age=600), so a new deploy shows up
  // on the next open instead of up to 10 minutes later.
  const request = isHtml ? fetch(event.request.url, { cache: 'no-cache', credentials: 'same-origin' }) : fetch(event.request);
  event.respondWith(
    request
      .then((res) => {
        // HTML is network-first and not written back, so phones/PCs
        // cannot stay stuck on an old index.js mixed with new data.
        if (!isHtml && res && res.ok) {
          const copy = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy)).catch(() => {});
        }
        return res;
      })
      .catch(() => caches.match(event.request).then((cached) => cached || caches.match('./index.html')))
  );
});
