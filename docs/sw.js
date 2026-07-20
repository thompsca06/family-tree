/* Service worker — makes the family tree readable with no signal.
 *
 * The whole site minus photographs is about 2.8 MB: every person, every record,
 * every story. That is small enough to keep permanently, so it is precached on
 * the first visit and the site then opens on a train, in a churchyard, or on a
 * plane with nothing at all.
 *
 * Photographs (157 MB) and map tiles are NOT precached — that would be a
 * punishing download on mobile data. They are kept as they are looked at, so a
 * page you have read once stays readable.
 *
 * THE UPDATE RULE, which matters because the site is rebuilt often:
 *   - the page and the DATA are network-first. A rebuild is picked up as soon as
 *     there is a connection, and the cache is only a fallback. A service worker
 *     that served stale data would quietly show yesterday's tree as though it
 *     were today's, which is exactly the kind of silent wrongness this project
 *     spends its time eliminating.
 *   - images, fonts and vendored libraries are cache-first. They never change
 *     without changing name, so serving them from disk is safe and fast.
 */
const VERSION = '20260720-060523';
const SHELL = 'ft-shell-' + VERSION;   // the page, the data, the libraries
const ASSETS = 'ft-assets-v1';         // photographs, fonts, map tiles

// Everything needed to read the site with no network at all.
const PRECACHE = [
  './',
  './index.html',
  './familydata.js',
  './support.js',
  './vendor/react.production.min.js',
  './vendor/react-dom.production.min.js',
  './vendor/leaflet.js',
  './vendor/leaflet.css'
];

self.addEventListener('install', (e) => {
  e.waitUntil((async () => {
    const c = await caches.open(SHELL);
    // addAll fails the whole install if ONE file 404s, which would leave no
    // offline copy at all and say nothing. Add them individually instead.
    await Promise.all(PRECACHE.map(u => c.add(u).catch(() => {})));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    // drop shells from older builds; keep the asset cache, which is version-free
    const keep = [SHELL, ASSETS];
    await Promise.all((await caches.keys()).map(k => keep.includes(k) ? null : caches.delete(k)));
    await self.clients.claim();
  })());
});

const isAsset = (url) =>
  /\.(jpg|jpeg|png|gif|webp|svg|woff2?|ttf)$/i.test(url.pathname) ||
  url.hostname.includes('fonts.gstatic.com') ||
  url.hostname.includes('fonts.googleapis.com') ||
  url.hostname.includes('basemaps.cartocdn.com');

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  // A navigation offline must land on the app, not a browser error page. The
  // site routes on the hash, so index.html answers every route.
  if (req.mode === 'navigate') {
    e.respondWith((async () => {
      try { return await fetch(req); }
      catch { return (await caches.match('./index.html')) || Response.error(); }
    })());
    return;
  }

  // Photographs, fonts, map tiles: from disk if we have them, else fetch and keep.
  if (isAsset(url)) {
    e.respondWith((async () => {
      const hit = await caches.match(req);
      if (hit) return hit;
      try {
        const res = await fetch(req);
        // opaque responses (no-cors tiles/fonts) are cacheable and worth keeping
        if (res && (res.ok || res.type === 'opaque')) {
          const c = await caches.open(ASSETS);
          c.put(req, res.clone());
        }
        return res;
      } catch {
        // no signal and never seen: let the map tile or photo fail quietly
        return Response.error();
      }
    })());
    return;
  }

  // The page, the data, the libraries: newest wins, cache is the fallback.
  e.respondWith((async () => {
    try {
      const res = await fetch(req);
      if (res && res.ok) {
        const c = await caches.open(SHELL);
        c.put(req, res.clone());
      }
      return res;
    } catch {
      const hit = await caches.match(req);
      return hit || Response.error();
    }
  })());
});
