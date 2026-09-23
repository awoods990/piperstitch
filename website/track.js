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
    // sendBeacon survives the page being closed mid-request; fetch is the
    // fallback where it isn't available.
    if (navigator.sendBeacon) navigator.sendBeacon(url, new Blob([body], { type: "application/json" }));
    else fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: body, keepalive: true, mode: "cors" });
  } catch (e) { /* analytics must never break a page */ }
})();
