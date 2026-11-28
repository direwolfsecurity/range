<?php
// geoip-demo.php - "Where am I?" for range web sites. From http://@SERVER_NAME@/download/
// Uses the Apache variables from mod_maxminddb when they are there (MM_CITY ...).
// Without them it opens the database itself (sudo apt install php-maxminddb).
// License: GPL-3.0, Dire Wolf Security.

$ip = $_SERVER['REMOTE_ADDR'] ?? '';
$where = [
    'how'      => 'Apache mod_maxminddb',
    'city'     => $_SERVER['MM_CITY'] ?? null,
    'region'   => $_SERVER['MM_REGION_NAME'] ?? null,
    'country'  => $_SERVER['MM_COUNTRY_NAME'] ?? null,
    'lat'      => $_SERVER['MM_LATITUDE'] ?? null,
    'lon'      => $_SERVER['MM_LONGITUDE'] ?? null,
    'tz'       => $_SERVER['MM_TIME_ZONE'] ?? null,
    'asn'      => $_SERVER['MM_ASN'] ?? null,
    'org'      => $_SERVER['MM_AS_ORG'] ?? null,
];

if ($where['country'] === null && class_exists('MaxMind\Db\Reader')) {
    $where['how'] = 'PHP MaxMind\Db\Reader';
    $city = new MaxMind\Db\Reader('/var/lib/GeoIP/GeoLite2-City.mmdb');
    $asn  = new MaxMind\Db\Reader('/var/lib/GeoIP/GeoLite2-ASN.mmdb');
    $c = $city->get($ip) ?? [];
    $a = $asn->get($ip) ?? [];
    $where['city']    = $c['city']['names']['en'] ?? null;
    $where['region']  = $c['subdivisions'][0]['names']['en'] ?? null;
    $where['country'] = $c['country']['names']['en'] ?? null;
    $where['lat']     = $c['location']['latitude'] ?? null;
    $where['lon']     = $c['location']['longitude'] ?? null;
    $where['tz']      = $c['location']['time_zone'] ?? null;
    $where['asn']     = $a['autonomous_system_number'] ?? null;
    $where['org']     = $a['autonomous_system_organization'] ?? null;
}

$h = fn($s) => htmlspecialchars((string)($s ?? 'unknown'), ENT_QUOTES);
?><!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Where am I?</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem}td{padding:.2rem .8rem}</style>
</head><body>
<h1>Hello from <?= $h($where['city']) ?>!</h1>
<table>
<tr><td>Your address</td><td><?= $h($ip) ?></td></tr>
<tr><td>City</td><td><?= $h($where['city']) ?>, <?= $h($where['region']) ?>, <?= $h($where['country']) ?></td></tr>
<tr><td>Map point</td><td><?= $h($where['lat']) ?>, <?= $h($where['lon']) ?></td></tr>
<tr><td>Time zone</td><td><?= $h($where['tz']) ?></td></tr>
<tr><td>Network</td><td>AS<?= $h($where['asn']) ?> <?= $h($where['org']) ?></td></tr>
<tr><td>Looked up by</td><td><?= $h($where['how']) ?></td></tr>
</table>
<p>Range data only: these places come from the range registry, not the real internet.</p>
</body></html>
