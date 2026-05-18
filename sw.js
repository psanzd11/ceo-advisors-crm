/* CEO Advisors CRM — Service Worker
   Network-first para navegaciones (HTML) — garantiza que cada deploy se vea
   en el siguiente refresh, sin esperar a que la cache se invalide sola.
   Cache-first para el resto de assets (fallback offline). */
const CACHE = 'ceoadvisors-crm-v3';
const ASSETS = [
  './',
  './index.html',
];

self.addEventListener('install', e => {
  self.skipWaiting();
  e.waitUntil(
    caches.open(CACHE).then(c => c.addAll(ASSETS).catch(()=>{}))
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys => Promise.all(
      keys.filter(k => k !== CACHE).map(k => caches.delete(k))
    )).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  const isHtml = e.request.mode === 'navigate'
              || url.pathname === '/'
              || url.pathname.endsWith('.html');

  if (isHtml) {
    /* Network-first: siempre intentar HTML fresco. Solo cae a cache si red falla. */
    e.respondWith(
      fetch(e.request).then(resp => {
        if (resp && resp.status === 200) {
          const copy = resp.clone();
          caches.open(CACHE).then(c => c.put(e.request, copy)).catch(()=>{});
        }
        return resp;
      }).catch(() => caches.match(e.request))
    );
  } else {
    /* Cache-first para assets estáticos */
    e.respondWith(
      caches.match(e.request).then(cached => {
        const fetchPromise = fetch(e.request).then(resp => {
          if (resp && resp.status === 200 && resp.type === 'basic') {
            const copy = resp.clone();
            caches.open(CACHE).then(c => c.put(e.request, copy)).catch(()=>{});
          }
          return resp;
        }).catch(() => cached);
        return cached || fetchPromise;
      })
    );
  }
});
