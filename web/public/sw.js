/* PiperStitch service worker. Exists so browsers offer "Install PiperStitch"
   (a Dock / taskbar / home-screen icon that opens the app in its own
   window). It deliberately caches nothing: every request goes straight to
   the network, so an update ships the moment it deploys and there is never
   a stale copy of the app to explain. */
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", (e) => { e.respondWith(fetch(e.request)); });
