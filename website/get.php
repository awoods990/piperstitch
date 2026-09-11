<?php
/**
 * PiperStitch — gated download. Same design as the Amerus site's get.php.
 *
 * The disk image lives in /downloads, which Apache is told to deny directly
 * (see downloads/.htaccess). Reachable two ways: the normal same-session
 * path right after registering, or a signed link from a reminder email —
 * that link carries ?email=&token=, an HMAC only License Admin and this
 * file can produce (must use the exact same DOWNLOAD_LINK_SECRET).
 *
 * Reaching the file also reports the download back to License Admin
 * (best-effort — never blocks the download), which is what lets the admin
 * tell "registered" apart from "actually downloaded".
 *
 * ------------------------------------------------------------------
 * SET THESE BEFORE GOING LIVE — must match license-admin's .env exactly:
 */
$LICENSE_ADMIN_URL = 'https://admin.piperstitch.com';
$LICENSE_ADMIN_API_KEY = '';
$DOWNLOAD_LINK_SECRET = '';
/* ------------------------------------------------------------------ */

session_start();

function ps_download_token(string $email, string $secret): string {
    return substr(hash_hmac('sha256', "download:$email", $secret), 0, 32);
}

$session_email = $_SESSION['ps_email'] ?? '';
$query_email   = isset($_GET['email']) ? strtolower(trim((string) $_GET['email'])) : '';
$query_token   = isset($_GET['token']) ? trim((string) $_GET['token']) : '';

$authorized = false;
$email = '';

if (!empty($_SESSION['ps_registered']) && $session_email !== '') {
    $authorized = true;
    $email = $session_email;
} elseif ($query_email !== '' && $query_token !== '' && $DOWNLOAD_LINK_SECRET !== '') {
    $expected = ps_download_token($query_email, $DOWNLOAD_LINK_SECRET);
    if (hash_equals($expected, $query_token)) {
        $authorized = true;
        $email = $query_email;
    }
}

if (!$authorized) {
    header('Location: download.html#register');
    exit;
}

$file = __DIR__ . '/downloads/PiperStitch.dmg';

if (!is_file($file)) {
    http_response_code(503);
    header('Content-Type: text/html; charset=UTF-8');
    echo '<!doctype html><meta charset="utf-8">'
       . '<title>Download unavailable</title>'
       . '<body style="font:16px -apple-system,Helvetica,Arial;max-width:36em;margin:12vh auto;padding:0 6vw;color:#161a20">'
       . '<h1 style="color:#0f2a4d">The download isn&rsquo;t available yet</h1>'
       . '<p>Your registration was recorded. The installer isn&rsquo;t posted on this server yet '
       . '&mdash; please try again shortly, or write to us and we will send it to you directly.</p>'
       . '<p><a href="index.html" style="color:#1a6fd1">Back to PiperStitch</a></p>';
    exit;
}

// --- report the completed download (best-effort — never blocks it) -----
if ($email !== '' && $LICENSE_ADMIN_API_KEY !== '' && function_exists('curl_init')) {
    $ch = curl_init($LICENSE_ADMIN_URL . '/api/download-confirmed');
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => json_encode(['email' => $email]),
        CURLOPT_HTTPHEADER     => ['Content-Type: application/json', 'X-API-Key: ' . $LICENSE_ADMIN_API_KEY],
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 4,
        CURLOPT_CONNECTTIMEOUT => 2,
    ]);
    @curl_exec($ch);
    curl_close($ch);
}

header('Content-Type: application/octet-stream');
header('Content-Disposition: attachment; filename="PiperStitch.dmg"');
header('Content-Length: ' . filesize($file));
header('X-Content-Type-Options: nosniff');
header('Cache-Control: private, no-store');
readfile($file);
