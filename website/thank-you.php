<?php
// Only reachable after a completed registration; otherwise send them back.
session_start();
if (empty($_SESSION['ps_registered'])) {
    header('Location: download.html#register');
    exit;
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Your PiperStitch download — thank you for registering</title>
<meta name="description" content="Your PiperStitch registration is complete. Download PiperStitch for Mac and make your first design in three steps.">
<link rel="canonical" href="https://www.piperstitch.com/thank-you.php">
<meta name="theme-color" content="#0f2a4d">

<meta property="og:type" content="website">
<meta property="og:site_name" content="PiperStitch">
<meta property="og:title" content="Your PiperStitch download — thank you for registering">
<meta property="og:description" content="Your PiperStitch registration is complete. Download PiperStitch for Mac and make your first design in three steps.">
<meta property="og:url" content="https://www.piperstitch.com/thank-you.php">
<meta property="og:image" content="https://www.piperstitch.com/assets/piperstitch-icon-512.png">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="Your PiperStitch download — thank you for registering">
<meta name="twitter:description" content="Your PiperStitch registration is complete. Download PiperStitch for Mac and make your first design in three steps.">
<meta name="twitter:image" content="https://www.piperstitch.com/assets/piperstitch-icon-512.png">

<link rel="icon" href="favicon.ico" sizes="any">
<link rel="icon" type="image/png" sizes="32x32" href="assets/piperstitch-mark-32.png">
<link rel="apple-touch-icon" href="assets/piperstitch-icon-180.png">
<link rel="stylesheet" href="styles.css">
</head>
<body>

<header class="site-header">
  <div class="header-inner">
    <a class="brand-link" href="index.html" aria-label="PiperStitch home">
      <img src="assets/piperstitch-mark-180.png" alt="" width="34" height="34">
      <span class="brand-word">Piper<span class="blue">Stitch</span><span class="brand-sub">EMBROIDERY DIGITIZING</span></span>
    </a>
    <button class="nav-toggle" id="navToggle" aria-label="Menu" aria-expanded="false" aria-controls="siteNav">
      <span></span><span></span><span></span>
    </button>
    <nav class="site-nav" id="siteNav">
      <a href="how-it-works.html">How It Works</a><a href="formats.html">Formats</a><a href="pricing.html">Pricing</a><a href="faq.html">FAQ</a>
      <a class="btn btn-primary" href="download.html">Download for Mac</a>
    </nav>
  </div>
</header>
<main>

<section class="page-hero sky">
  <div class="wrap">
    <div class="confirm">
      <div class="confirm-mark">
        <svg width="34" height="34" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M4 12.6l5 5L20 6.6" stroke="#fff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>
      </div>
      <p class="eyebrow">You&rsquo;re registered</p>
      <h1>Welcome to PiperStitch.</h1>
      <p class="lede">Your 14-day trial starts the first time you open the app. Your download is ready below.</p>
    </div>
  </div>
</section>

<section class="bg-white">
  <div class="wrap">
    <div class="download-card">
      <h2 style="font-size:1.5rem">PiperStitch for Mac</h2>
      <p class="muted small">Version 0.1.0 &middot; Apple silicon &middot; macOS 13 Ventura or later</p>
      <a class="btn btn-primary" href="get.php">Download PiperStitch</a>
      <p class="small muted" style="margin-top:20px">If the download doesn&rsquo;t begin automatically, <a href="get.php">click here to start it</a>.</p>
    </div>

    <div class="steps" style="margin:56px auto 0">
      <div class="step"><div class="step-n">1</div><div><h3>Drag PiperStitch to your Applications folder</h3><p>Open the disk image and drag the icon across. Then eject the disk image.</p></div></div>
      <div class="step"><div class="step-n">2</div><div><h3>Open it</h3><p>The first time, macOS may ask you to confirm &mdash; right-click the app and choose <strong>Open</strong>. No sign-in is needed during the trial.</p></div></div>
      <div class="step"><div class="step-n">3</div><div><h3>Drop in some artwork</h3><p>Set the size, hoop and fabric, click <strong>Create Embroidery File</strong>, and export for your machine.</p></div></div>
    </div>
  </div>
</section>

<section class="bg-line-top">
  <div class="wrap narrow">
    <p class="eyebrow">What happens with billing</p>
    <h2>Nothing, for 14 days.</h2>
    <p>No card was collected and no subscription is running. When the trial ends, PiperStitch shows a sign-in screen. If you want to keep going, subscribe for $19 a month on the pricing page &mdash; using this same email &mdash; then sign in inside the app. Cancel any time from your account page.</p>
    <div class="cta-row" style="margin-top:26px">
      <a class="btn btn-primary" href="pricing.html#subscribe">Subscribe &mdash; $19/month</a>
      <a class="btn btn-secondary" href="how-it-works.html">See how PiperStitch works</a>
    </div>
  </div>
</section>

</main>
<footer class="site-footer">
  <div class="wrap">
    <div class="footer-top">
      <div class="footer-brand">
        <img src="assets/piperstitch-logo-420.png" alt="PiperStitch" width="202">
        <p>Automatic embroidery digitizing for Mac. Turn any image into a machine-ready stitch file &mdash; in one click.</p>
      </div>
      <div>
        <h4>Product</h4>
        <ul>
          <li><a href="how-it-works.html">How It Works</a></li>
          <li><a href="formats.html">Formats &amp; Machines</a></li>
          <li><a href="system-requirements.html">System Requirements</a></li>
          <li><a href="download.html">Download for Mac</a></li>
        </ul>
      </div>
      <div>
        <h4>Account</h4>
        <ul>
          <li><a href="pricing.html">Pricing</a></li>
          <li><a href="pricing.html#subscribe">Subscribe</a></li>
          <li><a href="https://admin.piperstitch.com/account">Manage subscription</a></li>
          <li><a href="faq.html">FAQ</a></li>
        </ul>
      </div>
      <div>
        <h4>Legal</h4>
        <ul>
          <li><a href="terms.html">Terms of Use</a></li>
          <li><a href="privacy-policy.html">Privacy Policy</a></li>
          <li><a href="mailto:hello@piperstitch.com">Contact</a></li>
        </ul>
      </div>
    </div>
    <div class="footer-bottom">
      <span>&copy; <span id="year">2026</span> PiperStitch. All rights reserved. PiperStitch is not affiliated with Tajima, Brother, Baby Lock, Janome, Melco, or Bernina; their names identify file formats their machines read.</span>
      <span class="footer-motto">Turn any image into embroidery.</span>
    </div>
  </div>
</footer>
<script src="site.js"></script>
</body>
</html>
