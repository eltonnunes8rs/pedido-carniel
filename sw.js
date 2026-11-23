// Service worker do app Carniel — versão 22/11/2026
// Só guarda a "casca" (página e ícones) para abrir rápido e permitir instalar.
// Cardápio, login e pedido NUNCA vêm do cache: vão sempre ao servidor.
var V = "carniel-v1";
var CASCA = ["/", "/index.html", "/logo.png", "/icon-192.png", "/icon-512.png", "/manifest.webmanifest"];
self.addEventListener("install", function (e) {
  e.waitUntil(caches.open(V).then(function (c) { return c.addAll(CASCA); }).then(function () { return self.skipWaiting(); }));
});
self.addEventListener("activate", function (e) {
  e.waitUntil(caches.keys().then(function (ks) {
    return Promise.all(ks.filter(function (k) { return k !== V; }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});
self.addEventListener("fetch", function (e) {
  var r = e.request, u = new URL(r.url);
  if (r.method !== "GET" || u.origin !== location.origin) return;   // n8n e qualquer outro site: direto na rede
  // página: tenta a rede primeiro (sempre a versão nova); sem internet, usa a guardada
  e.respondWith(fetch(r).then(function (res) {
    if (res && res.ok) { var cp = res.clone(); caches.open(V).then(function (c) { c.put(r, cp); }); }
    return res;
  }).catch(function () { return caches.match(r).then(function (m) { return m || caches.match("/index.html"); }); }));
});
