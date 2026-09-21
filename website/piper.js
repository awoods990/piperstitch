/* Piper, the busy helper. The PiperStitch sandpiper turns up around the
   marketing pages -- looks at a heading, points at a button, cheers at the
   end -- and leaves. It is drawn from the character rig (PiperStitch General
   Files/Piper Character Rig/piper-rig.html: the same geometry, palette and
   poses as the promo films), so this is ~10 KB of JavaScript, crisp at any
   size, no video and no sprite sheet.

   House rules, all enforced here:
   - It reacts to what the visitor does (a section scrolling into view, a
     hover on the trial button, reaching the end of the page); never a timer.
   - Each moment plays once per session; at most four appearances per page
     view; never two at once; never over text -- it sits in the margin next
     to the thing he is reacting to. Phones get only the finale.
   - No sound, no words. Reduced-motion turns it off entirely.
   - localStorage "piperOff" = "1" turns it off for anyone who asks. */
(function () {
  "use strict";
  var reduced = matchMedia("(prefers-reduced-motion: reduce)").matches, off = false;
  try { off = localStorage.getItem("piperOff") === "1"; } catch (e) { /* fine */ }

  /* ── the rig (ported from piper-rig.html) ─────────────────────────── */
  var C = { rust: "#AA6334", rustD: "#7E4424", rustL: "#C98954", cream: "#F8F2E7", navy: "#112949",
            white: "#FFFFFF", blue: "#2B86E8", blueL: "#A2CEFA", sun: "#F2A93B", sea: "#3FB5A8", mouth: "#963C3E" };
  var BW = 300, BH = 250, ST = 4.5, FOOT = 224 / BH;
  var R = function (d) { return d * Math.PI / 180; };
  function poly(x, p) { x.beginPath(); x.moveTo(p[0][0], p[0][1]); for (var i = 1; i < p.length; i++) x.lineTo(p[i][0], p[i][1]); x.closePath(); }
  function fatPoly(x, p, col, grow) { poly(x, p); x.fillStyle = col; x.fill(); if (grow) { x.strokeStyle = col; x.lineWidth = grow * 2; x.lineJoin = "round"; x.lineCap = "round"; x.stroke(); } }
  function ell(x, cx, cy, rx, ry, col, grow) { x.beginPath(); x.ellipse(cx, cy, rx + (grow || 0), ry + (grow || 0), 0, 0, 6.2832); x.fillStyle = col; x.fill(); }
  function line(x, p, col, w) { x.beginPath(); x.moveTo(p[0][0], p[0][1]); for (var i = 1; i < p.length; i++) x.lineTo(p[i][0], p[i][1]); x.strokeStyle = col; x.lineWidth = w; x.lineJoin = "round"; x.lineCap = "round"; x.stroke(); }
  function wingPts(px, py, span, drop) {
    return [[px, py], [px + span * .30, py - 7], [px + span * .62, py - 5], [px + span * .88, py + 4], [px + span, py + 14],
            [px + span * .72, py + drop * .72], [px + span * .40, py + drop], [px + span * .14, py + drop * .82]];
  }
  var DEF = { wing: -14, wing2: null, span: 76, head: 0, eye: "normal", brow: 0, beak: 0, tail: 0, hop: 0, blink: 0, smile: 1 };
  var POSE = {
    idle: {}, curious: { wing: -16, head: 18, eye: "wide", beak: .2 }, think: { wing: -16, head: 16 },
    point: { wing: -2, span: 106 }, proud: { wing: -10, head: -8, eye: "happy", tail: 20, beak: .35 },
    tuck: { wing: -22, head: -6 }, gasp: { wing: 76, wing2: 92, eye: "wide", beak: 1, head: -10, tail: 14 },
    flap: { wing: 62, wing2: -18, hop: .9 }, cheer: { wing: 110, wing2: 128, hop: 1, eye: "happy", beak: 1, tail: 22 }
  };
  function drawPiper(x, o) {
    var p = {}, k; for (k in DEF) p[k] = DEF[k]; for (k in o) if (o[k] !== undefined) p[k] = o[k];
    var lift = p.hop * 14, by = -lift;
    [86, 118].forEach(function (lx, i) {
      var fy = 224 - (i ? lift * .55 : lift), kx = lx - 5 + i * 4, tipX = kx + 2 + i * 6;
      line(x, [[lx, 152 + by], [kx, 184], [tipX, fy]], C.navy, 5.5);
      [-12, -1, 10].forEach(function (tx) { line(x, [[tipX, fy], [tipX + tx, fy + 8]], C.navy, 4.5); });
    });
    var ta = R(p.tail), tl = 44, tx0 = 48, ty0 = 116 + by;
    var tailP = [[tx0, ty0 - 6], [tx0 - tl * Math.cos(ta) + 2, ty0 - tl * Math.sin(ta) - 22], [tx0 - tl * Math.cos(ta) - 6, ty0 - tl * Math.sin(ta) - 10],
                 [tx0 - tl * Math.cos(ta) + 4, ty0 - tl * Math.sin(ta) + 8], [tx0 + 2, ty0 + 18]];
    var neckP = [[120, 92 + by], [150, 100 + by], [168, 108 + by], [126, 116 + by]];
    var body = function (col, grow) { fatPoly(x, tailP, col, grow); ell(x, 100, 122 + by, 62, 49, col, grow); ell(x, 156, 70 + by, 41, 39, col, grow); fatPoly(x, neckP, col, grow); };
    body(C.navy, ST); body(C.cream, 0);
    x.save(); x.beginPath();
    x.moveTo(tailP[0][0], tailP[0][1]); for (var i = 1; i < tailP.length; i++) x.lineTo(tailP[i][0], tailP[i][1]); x.closePath();
    x.ellipse(100, 122 + by, 62, 49, 0, 0, 6.2832); x.ellipse(156, 70 + by, 41, 39, 0, 0, 6.2832);
    x.moveTo(neckP[0][0], neckP[0][1]); for (i = 1; i < neckP.length; i++) x.lineTo(neckP[i][0], neckP[i][1]); x.closePath(); x.clip();
    fatPoly(x, [[30, 116 + by], [52, 82 + by], [92, 66 + by], [134, 74 + by], [158, 92 + by], [150, 104 + by], [112, 88 + by], [70, 96 + by], [44, 124 + by]], C.rust, 0);
    fatPoly(x, [[120, 44 + by], [140, 28 + by], [168, 26 + by], [192, 40 + by], [196, 58 + by], [172, 44 + by], [140, 44 + by]], C.rust, 0);
    line(x, [[58, 104 + by], [94, 92 + by], [128, 94 + by]], C.rustD, 3.5);
    line(x, [[52, 116 + by], [88, 104 + by], [124, 106 + by]], C.rustL, 3);
    x.restore();
    var wing = function (ang, col, px, py, span, drop) {
      x.save(); x.translate(px, py + by); x.rotate(-R(ang)); x.translate(-px, -(py + by));
      var pts = wingPts(px, py + by, span, drop);
      fatPoly(x, pts, C.navy, ST * .8); fatPoly(x, pts, col, 0);
      line(x, [[px + span * .30, py + by + 6], [px + span * .62, py + by + 9], [px + span * .84, py + by + 16]], col === C.rust ? C.rustD : C.rust, 2.5);
      x.restore();
    };
    if (p.wing2 !== null && p.wing2 !== undefined) wing(p.wing2, C.rustD, 96, 100, 70, 27);
    wing(p.wing, C.rust, 100, 104, p.span, 30);
    var hx = 156, hy = 70 + by, bo = p.beak * 13;
    x.save(); x.translate(hx - 30, hy + 26); x.rotate(-R(p.head)); x.translate(-(hx - 30), -(hy + 26));
    x.save(); x.translate(hx + 32, hy + 4); x.rotate(-R(bo * .45)); x.translate(-(hx + 32), -(hy + 4));
    fatPoly(x, [[hx + 32, hy - 5], [hx + 112, hy + 7], [hx + 108, hy + 11], [hx + 32, hy + 5]], C.navy, 0); x.restore();
    x.save(); x.translate(hx + 32, hy + 4); x.rotate(R(bo)); x.translate(-(hx + 32), -(hy + 4));
    fatPoly(x, [[hx + 32, hy + 5], [hx + 106, hy + 11], [hx + 102, hy + 15], [hx + 32, hy + 13]], C.navy, 0); x.restore();
    if (p.beak > .25) fatPoly(x, [[hx + 34, hy + 1], [hx + 62, hy + 2 + bo * .5], [hx + 34, hy + 9]], C.mouth, 0);
    var ex = hx + 15, ey = hy - 9, eye = p.blink > .5 ? "closed" : p.eye;
    if (eye === "closed") line(x, [[ex - 10, ey], [ex + 10, ey]], C.navy, 4);
    else if (eye === "happy") line(x, [[ex - 11, ey + 4], [ex - 4, ey - 7], [ex + 3, ey - 8], [ex + 11, ey + 2]], C.navy, 5);
    else if (eye === "wide") { ell(x, ex + 1, ey - 1, 16.5, 16.5, C.navy); ell(x, ex + 1, ey - 1, 14, 14, C.white); ell(x, ex + 3, ey + 1, 8, 8, C.navy); ell(x, ex + 5.5, ey - 2, 3, 3, C.white); }
    else { ell(x, ex, ey, 11, 11, C.navy); ell(x, ex + 4, ey - 4, 4, 4, C.white); ell(x, ex - 3.5, ey + 4, 1.9, 1.9, C.white); }
    if (Math.abs(p.brow) > .05) line(x, [[ex - 12, ey - 19 + p.brow * 7], [ex + 11, ey - 19 - p.brow * 7]], C.navy, 4.5);
    if (p.smile > .02) line(x, [[hx + 2, hy + 16], [hx + 14, hy + 20 + p.smile * 3]], C.rustD, 2.6);
    x.restore();
  }
  /* Piper with its feet at (fx, fy), h tall, with squash, tilt and facing. */
  function place(x, fx, fy, h, o) {
    var s = h / BH;
    x.save(); x.translate(fx, fy - h * (FOOT - .5));      // the bird's centre; feet are h*(FOOT-.5) below it
    if (o.tilt) x.rotate(-R(o.tilt));
    x.scale(s * (o.sx || 1) * (o.flip ? -1 : 1), s * (o.sy || 1)); x.translate(-BW / 2, -BH / 2);
    drawPiper(x, o); x.restore();
  }
  function bob(n) { return { hop: .26 * (.5 + .5 * Math.sin(n * .11)), head: 2.6 * Math.sin(n * .11 * .63), blink: (n % 97) < 4 ? 1 : 0 }; }
  var settle = function (k) { return Math.sin(k * Math.PI * 2) * Math.exp(-k * 3) * .22; };
  var easeOut = function (q) { return 1 - Math.pow(1 - q, 3); };

  /* confetti of stitch-dashes, the film's celebration glyph */
  function confetti(n, ox, oy, scale) {
    var pts = [], cols = [C.sun, C.blueL, C.blue, C.sea, C.rust];
    for (var i = 0; i < n; i++) {
      var a = (i / n) * Math.PI * 2 + (i % 3) * .3, sp = (28 + (i * 37) % 23) * scale;
      pts.push({ a: a, sp: sp, col: cols[i % cols.length], rot: (i * 53) % 360, ox: ox, oy: oy, len: (7 + i % 5) * scale });
    }
    return pts;
  }
  function drawConfetti(x, pts, t) {  /* t: 0..1 */
    pts.forEach(function (c) {
      var d = c.sp * easeOut(t) * 3.2, px = c.ox + Math.cos(c.a) * d, py = c.oy + Math.sin(c.a) * d + t * t * 90;
      x.save(); x.globalAlpha = 1 - Math.max(0, t - .6) / .4; x.translate(px, py); x.rotate(R(c.rot + t * 240));
      x.fillStyle = c.col; x.fillRect(-c.len / 2, -c.len * .18, c.len, c.len * .36); x.restore();
    });
  }

  /* ── Get Piper: Piper at rest in the section that explains the install ── */
  var getBird = document.getElementById("getPiperBird");
  if (getBird) {
    var gb = getBird.getContext("2d"), gdpr = Math.min(devicePixelRatio || 1, 2);
    var GW = getBird.clientWidth || 300, GH = getBird.clientHeight || 260, gh = GH * .62;
    getBird.width = GW * gdpr; getBird.height = GH * gdpr; gb.scale(gdpr, gdpr);
    var gframe = 0, waveAt = 150;
    var drawIdle = function () {
      gb.clearRect(0, 0, GW, GH);
      var b = bob(gframe), pose = { hop: b.hop, head: b.head, blink: b.blink }, fy = GH * .92, w = gframe - waveAt;
      if (w >= 0 && w < 70) {            // now and then: a hop and a wave
        if (w < 8) { var e = easeOut(w / 8); pose.sx = 1 + .2 * e; pose.sy = 1 - .18 * e; }
        else if (w < 36) { var q = (w - 8) / 28; fy -= Math.sin(q * Math.PI) * gh * .32; pose.wing = 60 + 40 * Math.sin(q * Math.PI * 3); pose.wing2 = 120; pose.eye = "happy"; pose.beak = .4; pose.tail = 18; pose.hop = 1; }
        else if (w < 50) { var sl = settle((w - 36) / 14); pose.sx = 1 + sl; pose.sy = 1 - sl; pose.eye = "happy"; }
        if (w === 69) waveAt = gframe + 200 + Math.floor(Math.random() * 200);
      }
      place(gb, GW * .5, fy, gh, pose);
    };
    drawIdle();
    if (!reduced) {
      var idleOn = false, idleRaf = 0;
      var loop = function () { gframe++; drawIdle(); idleRaf = requestAnimationFrame(loop); };
      new IntersectionObserver(function (en) {      // only animate while it's on screen
        var vis = en[0].isIntersecting;
        if (vis && !idleOn) { idleOn = true; idleRaf = requestAnimationFrame(loop); }
        if (!vis && idleOn) { idleOn = false; cancelAnimationFrame(idleRaf); }
      }).observe(getBird);
    }
  }
  var shortcutBtn = document.getElementById("getPiperShortcut");
  if (shortcutBtn) shortcutBtn.addEventListener("click", function () {
    var url = "https://app.piperstitch.com/?source=shortcut", win = /Win/.test(navigator.platform);
    var name = win ? "PiperStitch.url" : "PiperStitch.webloc";
    var body = win ? "[InternetShortcut]\r\nURL=" + url + "\r\n"
      : '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>URL</key><string>' + url + "</string></dict></plist>\n";
    var a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([body], { type: win ? "application/internet-shortcut" : "application/xml" }));
    a.download = name; document.body.appendChild(a); a.click(); a.remove();
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 2000);
  });

  if (reduced || off) return;   // the helper below only runs for people who want motion

  /* ── one appearance: a canvas next to an anchor, a small timeline ─── */
  var active = null, shown = 0, MAX_PER_PAGE = 4;
  var page = location.pathname.replace(/[^a-z0-9]/gi, "") || "index";
  function once(key) {
    var k = "piper:" + page + ":" + key;
    try { if (sessionStorage.getItem(k)) return false; sessionStorage.setItem(k, "1"); } catch (e) { /* fine */ }
    return true;
  }
  var mobile = function () { return innerWidth < 640; };

  /* Where it stands. `side`: "right" of the anchor (in the margin), "above"
     (on the band, centred), or "band" (bottom edge of a full-width band). */
  function spotFor(anchor, side, h) {
    var r = anchor.getBoundingClientRect(), sy = scrollY, sx = scrollX;
    var wrap = anchor.closest(".wrap"), wr = wrap ? wrap.getBoundingClientRect() : { right: innerWidth - 24, left: 24 };
    if (side === "right") {
      var room = Math.min(wr.right, innerWidth - 12) - r.right;
      if (room >= h * 1.15) return { fx: sx + r.right + h * .55, fy: sy + r.bottom - 2, flip: false };
      side = "above";
    }
    if (side === "above") return { fx: sx + r.left + r.width / 2, fy: sy + r.top - 6, flip: false };
    return { fx: sx + Math.min(wr.right, innerWidth - 24) - h * .6, fy: sy + r.bottom - 8, flip: true };
  }

  function show(spec) {
    if (active || shown >= MAX_PER_PAGE) return false;
    var h = spec.h || (mobile() ? 78 : 118), pad = h * 1.6;
    var spot = spotFor(spec.anchor, spec.side, h);
    if (spot.fy - sy() < -h || spot.fy - sy() > innerHeight + h) return false;   // off screen right now: another time
    if (!once(spec.key)) return false;
    var cv = document.createElement("canvas"), W = Math.round(pad * 2.4), H = Math.round(pad * 2.1);
    var dpr = Math.min(devicePixelRatio || 1, 2);
    cv.width = W * dpr; cv.height = H * dpr;
    cv.style.cssText = "position:absolute;pointer-events:none;z-index:40;width:" + W + "px;height:" + H + "px;left:" +
      Math.round(spot.fx - W * .5) + "px;top:" + Math.round(spot.fy - H * .78) + "px";
    cv.setAttribute("aria-hidden", "true");
    document.body.appendChild(cv);
    var x = cv.getContext("2d"); x.scale(dpr, dpr);
    var feetX = W * .5, feetY = H * .78, frame = 0, start = performance.now(), dead = false;
    var hold = spec.hold || 5200, enter = spec.enter || "walk";
    var burst = null;
    shown++; active = spec.key;
    function done() { if (dead) return; dead = true; active = null; cv.remove(); }
    spec.onStart && spec.onStart();
    function tick(now) {
      if (dead) return;
      var t = now - start; frame++;
      x.clearRect(0, 0, W, H);
      var b = bob(frame), pose = {}, k, fx = feetX, fy = feetY, alpha = 1;
      var P = POSE[spec.pose] || {};
      for (k in P) pose[k] = P[k];
      if (pose.hop === undefined) pose.hop = b.hop; if (pose.head === undefined) pose.head = b.head; pose.blink = b.blink; pose.flip = spot.flip;

      if (enter === "walk" && t < 700) {                 // walk in from the side
        var q = t / 700, e = easeOut(q), wb = Math.abs(Math.sin(t / 150 * Math.PI));
        fx = feetX + (spot.flip ? 1 : -1) * (1 - e) * h * 1.3; fy = feetY - wb * 4; alpha = Math.min(1, q * 3);
        pose.wing = -12; pose.tail = 8; pose.head = 0; pose.eye = "normal"; pose.beak = 0;
      } else if (enter === "drop" && t < 900) {          // drop in from above, settle
        var q2 = t / 900;
        if (q2 < .55) { var d = q2 / .55; fy = feetY - (1 - d * d) * h * 1.6; pose.wing = 62 + 22 * Math.sin(frame * .9); pose.wing2 = -18; pose.hop = 1; pose.eye = "happy"; alpha = Math.min(1, d * 2.5); }
        else { var s = settle((q2 - .55) / .45); pose.sx = 1 + s; pose.sy = 1 - s; }
      } else if (spec.pose === "cheer" && t < 700 + 1100) {   // leap + 360 with confetti, from the film's finale
        var tt = t - 700, ANT = 200, AIR = 620, LAND = 280;
        if (tt < ANT) { var ea = easeOut(tt / ANT); pose.sx = 1 + .22 * ea; pose.sy = 1 - .20 * ea; pose = Object.assign(pose, { wing: -14, wing2: null, hop: 0, eye: "normal", beak: 0, tail: 0 }); }
        else if (tt < ANT + AIR) { var qa = (tt - ANT) / AIR, v = Math.abs(Math.cos(qa * Math.PI)); fy = feetY - Math.sin(qa * Math.PI) * h * 1.15; pose.tilt = (spot.flip ? 360 : -360) * qa; pose.sx = 1 - .15 * v; pose.sy = 1 + .15 * v; if (!burst && qa > .45) burst = { pts: confetti(26, feetX, feetY - h * .9, h / 118), at: now }; }
        else { var kl = (tt - ANT - AIR) / LAND, sl = settle(kl); pose.sx = 1 + sl; pose.sy = 1 - sl; }
      } else if (t > hold) {                             // leave: hop off and fade
        var q3 = (t - hold) / 520; if (q3 >= 1) return done();
        fx = feetX + (spot.flip ? 1 : -1) * easeOut(q3) * h * 1.4; fy = feetY - Math.sin(q3 * Math.PI) * h * .5; alpha = 1 - q3;
        pose.wing = 62 + 22 * Math.sin(frame * .9); pose.wing2 = -18; pose.hop = 1; pose.eye = "happy";
        if (spec.exitPose) { P = POSE[spec.exitPose]; for (k in P) pose[k] = P[k]; }
      }
      if (burst) { var bt = (now - burst.at) / 1500; if (bt < 1) drawConfetti(x, burst.pts, bt); }
      x.save(); x.globalAlpha = alpha; place(x, fx, fy, h, pose); x.restore();
      requestAnimationFrame(tick);
    }
    requestAnimationFrame(tick);
    // It leaves early if the visitor scrolls it out of view.
    var onScroll = function () { var r = cv.getBoundingClientRect(); if (r.bottom < -40 || r.top > innerHeight + 40) { done(); removeEventListener("scroll", onScroll); } };
    addEventListener("scroll", onScroll, { passive: true });
    return { leave: function () { hold = Math.min(hold, Math.max(900, performance.now() - start)); } };
  }
  function sy() { return scrollY; }

  /* ── the moments ───────────────────────────────────────────────────── */
  function firstMatch(sel) { for (var i = 0; i < sel.length; i++) { var el = document.querySelector(sel[i]); if (el) return el; } return null; }
  function headingWith(words) {
    var hs = document.querySelectorAll("h2");
    for (var i = 0; i < hs.length; i++) { var t = hs[i].textContent.toLowerCase(); for (var j = 0; j < words.length; j++) if (t.indexOf(words[j]) >= 0) return hs[i]; }
    return null;
  }
  var moments = [];
  function when(el, key, spec) { if (!el) return; spec.anchor = el; spec.key = key; moments.push(spec); }

  // A heading it reacts to as the heading scrolls in: proofs -> curious, results ->
  // proud, pricing -> think, steps/formats -> point. Desktop only.
  if (!mobile()) {
    when(headingWith(["send a proof", "doesn't stall", "doesn’t stall", "go ahead"]), "proof", { pose: "curious", side: "right", enter: "walk", hold: 5200 });
    when(headingWith(["professional results", "not a tracer", "rules, not guesses"]), "proud", { pose: "proud", side: "right", enter: "drop", hold: 4200 });
    when(headingWith(["a month", "no surprises", "three proofs on us"]), "price", { pose: "think", side: "right", enter: "walk", hold: 4800 });
    when(headingWith(["six steps", "speaks your machine", "three steps", "every embroidery design"]), "steps", { pose: "point", side: "right", enter: "walk", hold: 4200 });
  }
  // The finale: the closing call-to-action band on every page. It drops
  // onto the band and does the leap-and-360 with confetti, once.
  var band = firstMatch([".cta-band .cta-row", ".cta-band h2", "main > section:last-of-type h2"]);
  when(band, "finale", { pose: "cheer", side: mobile() ? "above" : "band", enter: "drop", hold: 3400, h: mobile() ? 84 : 132 });

  // A heading has to stay in view for a moment before it reacts -- scrolling
  // straight past it is not "reading it", and smooth scrolling keeps the
  // page moving for a while after a jump.
  var pending = {};
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (en) {
      var spec = moments.filter(function (m) { return m.anchor === en.target; })[0];
      if (!spec) return;
      if (!en.isIntersecting || en.intersectionRatio < .6) { clearTimeout(pending[spec.key]); delete pending[spec.key]; return; }
      if (pending[spec.key]) return;
      pending[spec.key] = setTimeout(function () {
        delete pending[spec.key];
        var r = en.target.getBoundingClientRect();
        if (r.bottom < 0 || r.top > innerHeight) return;
        if (show(spec)) io.unobserve(en.target);
      }, spec.pose === "cheer" ? 400 : 900);
    });
  }, { threshold: [.6] });
  moments.forEach(function (m) { io.observe(m.anchor); });

  // A peek at the trial button while it's hovered: he pops up above it,
  // curious, and goes when the pointer leaves. Once per page view.
  if (!mobile() && matchMedia("(hover: hover)").matches) {
    var trial = document.querySelector("main .btn-primary, .hero .btn-primary");
    if (trial) {
      var peek = null;
      trial.addEventListener("mouseenter", function () {
        if (peek || active) return;
        peek = show({ anchor: trial, key: "peek", pose: "curious", side: "above", enter: "drop", hold: 8000, h: 96, exitPose: "proud" }) || null;
      });
      trial.addEventListener("mouseleave", function () { if (peek) peek.leave(); });
    }
  }
})();
