<?php
/**
 * PiperStitch — download registration handler.
 *
 * Same design as the Amerus site's register.php: validates the download
 * form, records the acceptance of the Terms and Privacy Policy with a
 * timestamp, notifies you by email, forwards the registration to the
 * License Admin service (so a customer record exists before any
 * subscription — a later subscription under the same email connects to
 * it), and unlocks the download.
 *
 * No payment information is requested, received, or stored here. The
 * 14-day trial clock runs inside the app itself, not on this server.
 *
 * ------------------------------------------------------------------
 * SET THESE BEFORE GOING LIVE:
 */
$OWNER_EMAIL = 'hello@piperstitch.com';    // where registration notices are sent
$FROM_EMAIL  = 'no-reply@piperstitch.com'; // must be an address on your own domain
$LICENSE_ADMIN_URL = 'https://admin.piperstitch.com';
// Must match INTAKE_API_KEY in license-admin's .env on the server — see
// that project's README for how it's generated.
$LICENSE_ADMIN_API_KEY = '';
/* ------------------------------------------------------------------ */

session_start();

const STORE_DIR = __DIR__ . '/private';
const STORE_CSV = STORE_DIR . '/registrations.csv';
const TRIAL_DAYS = 14;
const MONTHLY_PRICE = '19.00';

function back_with_error(string $code): void {
    header('Location: download.html?err=' . urlencode($code) . '#register');
    exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    header('Location: download.html#register');
    exit;
}

// --- spam trap: a hidden field real people never fill in ---------------
if (!empty($_POST['company_website'])) {
    header('Location: download.html#register');
    exit;
}

function ps_cut(string $v, int $max): string {
    return function_exists('mb_substr') ? mb_substr($v, 0, $max) : substr($v, 0, $max);
}

$field = static function (string $k, int $max = 200): string {
    $v = isset($_POST[$k]) ? trim((string) $_POST[$k]) : '';
    $v = str_replace(["\r", "\n", "\0"], ' ', $v);   // header-injection guard
    return ps_cut($v, $max);
};

$first   = $field('first_name', 80);
$last    = $field('last_name', 80);
$email   = strtolower($field('email', 190));
$machine = $field('machine', 120);      // optional
$org     = $field('organization', 120); // optional
$tver    = $field('terms_version', 20);

// --- validation --------------------------------------------------------
if ($first === '' || $last === '')                               back_with_error('name');
if ($email === '' || !filter_var($email, FILTER_VALIDATE_EMAIL)) back_with_error('email');
if (($_POST['accept_terms']   ?? '') !== 'yes')                  back_with_error('terms');
if (($_POST['accept_billing'] ?? '') !== 'yes')                  back_with_error('billing');
if (($_POST['accept_age']     ?? '') !== 'yes')                  back_with_error('age');

$now        = gmdate('Y-m-d H:i:s') . ' UTC';
$now_iso    = gmdate('Y-m-d\TH:i:s\Z');
$trial_ends = gmdate('Y-m-d', time() + TRIAL_DAYS * 86400);  // an estimate: the real clock starts at first launch
$ip = $_SERVER['REMOTE_ADDR'] ?? '';
$ua = ps_cut(str_replace(["\r", "\n"], ' ', $_SERVER['HTTP_USER_AGENT'] ?? ''), 250);

// --- record it ---------------------------------------------------------
// The CSV is the durable, on-this-server record of who accepted which
// version of the Terms — kept regardless of whether the License Admin
// push below succeeds, so a registration is never lost to a network blip.
if (!is_dir(STORE_DIR)) {
    @mkdir(STORE_DIR, 0700, true);
}
$new = !file_exists(STORE_CSV);
if ($fh = @fopen(STORE_CSV, 'a')) {
    if (flock($fh, LOCK_EX)) {
        if ($new) {
            fputcsv($fh, ['timestamp_utc', 'first_name', 'last_name', 'email', 'machine', 'organization',
                          'trial_days', 'trial_ends_estimate', 'terms_version', 'accepted_terms',
                          'accepted_billing', 'accepted_age', 'ip', 'user_agent']);
        }
        fputcsv($fh, [$now, $first, $last, $email, $machine, $org, TRIAL_DAYS, $trial_ends, $tver,
                      'yes', 'yes', 'yes', $ip, $ua]);
        fflush($fh);
        flock($fh, LOCK_UN);
    }
    fclose($fh);
    @chmod(STORE_CSV, 0600);
}

// --- forward to License Admin (best-effort — never blocks registration) --
if ($LICENSE_ADMIN_API_KEY !== '' && function_exists('curl_init')) {
    $payload = json_encode([
        'name'                  => trim("$first $last"),
        'email'                 => $email,
        'phone'                 => '',
        'address'               => $machine !== '' ? "Machine: $machine" : '',
        'consent_terms_version' => $tver,
        'consent_accepted_at'   => $now_iso,
    ]);
    $ch = curl_init($LICENSE_ADMIN_URL . '/api/customers');
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => $payload,
        CURLOPT_HTTPHEADER     => ['Content-Type: application/json', 'X-API-Key: ' . $LICENSE_ADMIN_API_KEY],
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 5,
        CURLOPT_CONNECTTIMEOUT => 3,
    ]);
    @curl_exec($ch);
    curl_close($ch);
}

// --- notify you --------------------------------------------------------
$subject = 'PiperStitch registration: ' . $first . ' ' . $last;
$body = "New PiperStitch download registration.\n\n"
      . "Name:         $first $last\n"
      . "Email:        $email\n"
      . "Machine:      " . ($machine !== '' ? $machine : '-') . "\n"
      . "Business:     " . ($org !== '' ? $org : '-') . "\n\n"
      . "Trial:        " . TRIAL_DAYS . " days from first launch (ends around $trial_ends if they open it today)\n"
      . "Then:         \$" . MONTHLY_PRICE . "/month subscription, started by them on the pricing page\n\n"
      . "Accepted Terms and Privacy Policy: yes (version $tver)\n"
      . "Accepted trial/subscription terms: yes\n"
      . "Confirmed 18 or older:             yes\n"
      . "Recorded:     $now\n"
      . "IP:           $ip\n";
$headers = "From: PiperStitch Website <$FROM_EMAIL>\r\n"
         . "Reply-To: $email\r\n"
         . "Content-Type: text/plain; charset=UTF-8\r\n";
@mail($OWNER_EMAIL, $subject, $body, $headers);

// --- unlock the download ----------------------------------------------
$_SESSION['ps_registered'] = true;
$_SESSION['ps_name']       = $first;
$_SESSION['ps_email']      = $email;  // get.php reports the completed download under this
header('Location: thank-you.php');
exit;
