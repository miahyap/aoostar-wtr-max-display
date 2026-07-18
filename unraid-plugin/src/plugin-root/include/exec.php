<?php
/* Button backend for the aoostar-lcd plugin settings page.
 * Served by the Unraid webgui (behind its authentication). Only a fixed
 * whitelist of rc-script actions can be invoked. */
$allowed = ['start', 'stop', 'restart', 'status', 'install', 'sensors', 'on', 'off'];
$cmd = $_POST['cmd'] ?? '';
if (!in_array($cmd, $allowed, true)) {
  http_response_code(400);
  exit('invalid command');
}
header('Content-Type: text/plain; charset=utf-8');
passthru('/usr/local/emhttp/plugins/aoostar-lcd/scripts/rc.aoostar-lcd ' . escapeshellarg($cmd) . ' 2>&1');
