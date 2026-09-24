// First-party analytics: one small POST per page, to our own server.
//
// No cookie, no device id, nothing stored in this browser. The server
// counts a visitor as a salted one-way digest of address, browser and
// today's date, so the same person tomorrow is a different number and
// nobody can work backwards to an address. The referrer is reduced to
// its host there too: we learn that someone came from youtube.com, never
// which video. Do Not Track is honoured on both sides.
(function () {
  try {
    if (navigator.doNotTrack === "1" || window.doNotTrack === "1" || navigator.globalPrivacyControl) return;
    if (location.hostname === "localhost" || location.hostname === "127.0.0.1") return;
    var q = new URLSearchParams(location.search);
    var body = JSON.stringify({
      path: location.pathname,
      referrer: document.referrer || "",
      source: q.get("utm_source") || q.get("ref") || "",
      medium: q.get("utm_medium") || "",
      campaign: q.get("utm_campaign") || "",
    });
    var url = "https://admin.piperstitch.com/api/track";
    // keepalive makes this survive the page being closed mid-request, the
    // one thing sendBeacon was here for. sendBeacon itself cannot be used:
    // it always sends with credentials, which forces a preflight the server
    // would have to answer with Allow-Credentials -- and sending our cookies
    // along with a page view we promise is cookieless is the wrong trade.
    // text/plain is CORS-safelisted, so there is no preflight at all.
    fetch(url, { method: "POST", headers: { "Content-Type": "text/plain" }, body: body,
                 keepalive: true, mode: "cors", credentials: "omit" });
  } catch (e) { /* analytics must never break a page */ }
})();
