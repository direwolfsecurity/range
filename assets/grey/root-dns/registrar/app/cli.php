<?php
// Range Registrar CLI — run as www-data so the DB stays owned by the web app:
//   sudo -u www-data php /opt/registrar/cli.php <command> ...
//   add-tld <tld>...            add TLD(s)
//   del-tld <tld>               remove TLD and its domains
//   add-a <name.tld> <ip>       register a domain with a simple A record
//   add-ns <name.tld> <ns1> [glue1] [ns2] [glue2]
//   del <name.tld>              delete a domain
//   list                        list everything
//   open | close                open/close public registration
//   export                      print every TLD, domain and setting as JSON (a snapshot)
//   import                      replace EVERYTHING with a snapshot read from stdin (JSON from export)
// add-a and add-ns take an optional last argument --registrant=NAME (default "Range Admin").
// Then publish: sudo registrar-apply
require __DIR__ . '/lib.php';
if (PHP_SAPI !== 'cli') exit;

$cmd = $argv[1] ?? ''; $args = array_slice($argv, 2);
// Optional --registrant=NAME (used by the range control server to tag exercise domains).
$who = 'Range Admin';
foreach ($args as $i => $a) {
    if (str_starts_with($a, '--registrant=')) { $who = substr($a, 13); unset($args[$i]); }
}
$args = array_values($args);
if ($who === '' || mb_strlen($who) > 100) { fwrite(STDERR, "error: bad --registrant\n"); exit(1); }
function fail(string $m): never { fwrite(STDERR, "error: $m\n"); exit(1); }
function need_dom(string $s): array { [$l, $t] = split_fqdn($s); if (!valid_label($l) || !in_array($t, tlds(), true)) fail("bad domain or unknown TLD: $s"); return [$l, $t]; }
function insert(string $l, string $t, array $rec, string $who = 'Range Admin'): void {
    if (find_domain($l, $t)) fail("$l.$t already registered");
    $code = gen_code();
    db()->prepare('INSERT INTO domains (label,tld,mode,ns1,ns1_ip,ns2,ns2_ip,a_ip,registrant,code_hash) VALUES (?,?,?,?,?,?,?,?,?,?)')
        ->execute([$l, $t, $rec['mode'], $rec['ns1'], $rec['ns1_ip'], $rec['ns2'], $rec['ns2_ip'], $rec['a_ip'], $who, password_hash($code, PASSWORD_DEFAULT)]);
    echo "registered $l.$t  (management code: $code)\n";
}

switch ($cmd) {
    case 'add-tld':
        foreach ($args as $t) { $t = strtolower(trim($t, '. ')); if (!valid_label($t)) fail("bad TLD $t");
            db()->prepare('INSERT OR IGNORE INTO tlds (name) VALUES (?)')->execute([$t]); echo "TLD .$t\n"; }
        break;
    case 'del-tld':
        $t = strtolower(trim($args[0] ?? '', '. '));
        db()->prepare('DELETE FROM domains WHERE tld = ?')->execute([$t]); db()->prepare('DELETE FROM tlds WHERE name = ?')->execute([$t]);
        echo "removed .$t\n"; break;
    case 'add-a':
        [$l, $t] = need_dom($args[0] ?? '');
        [$rec, $e] = validate_records(['mode' => 'a', 'a_ip' => $args[1] ?? ''], "$l.$t"); if ($e) fail(implode(' ', $e));
        insert($l, $t, $rec, $who); break;
    case 'add-ns':
        [$l, $t] = need_dom($args[0] ?? '');
        [$rec, $e] = validate_records(['mode' => 'ns', 'ns1' => $args[1] ?? '', 'ns1_ip' => $args[2] ?? '', 'ns2' => $args[3] ?? '', 'ns2_ip' => $args[4] ?? ''], "$l.$t");
        if ($e) fail(implode(' ', $e)); insert($l, $t, $rec, $who); break;
    case 'del':
        [$l, $t] = need_dom($args[0] ?? '');
        db()->prepare('DELETE FROM domains WHERE label = ? AND tld = ?')->execute([$l, $t]); echo "deleted $l.$t\n"; break;
    case 'list':
        echo 'TLDs: ' . implode(' ', tlds()) . '   registration: ' . (setting('open_registration', '1') === '1' ? 'open' : 'closed') . "\n";
        foreach (db()->query('SELECT * FROM domains ORDER BY tld, label') as $d)
            printf("  %-32s %-9s %-40s %s\n", "$d[label].$d[tld]", $d['status'], records_summary($d), $d['registrant']);
        break;
    case 'export':
        echo json_encode(export_all(), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n"; break;
    case 'import':
        $snap = json_decode(stream_get_contents(STDIN), true);
        if (!is_array($snap)) fail('stdin is not JSON from "export"');
        $n = import_all($snap);
        echo "imported $n domain(s); now run registrar-apply\n"; break;
    case 'open': case 'close':
        set_setting('open_registration', $cmd === 'open' ? '1' : '0'); echo "registration $cmd\n"; break;
    default:
        echo implode("\n", array_slice(file(__FILE__, FILE_IGNORE_NEW_LINES), 1, 14)), "\n"; exit(1);
}

// Everything the registrar knows, as one array. The management codes stay hashed.
function export_all(): array {
    return [
        'format' => 'registrar-snapshot-1',
        'open_registration' => setting('open_registration', '1'),
        'tlds' => tlds(),
        'domains' => db()->query('SELECT label, tld, mode, ns1, ns1_ip, ns2, ns2_ip, a_ip, registrant, email, org,
                                         code_hash, status, created_at, updated_at FROM domains ORDER BY tld, label')->fetchAll(),
    ];
}

// Replace everything with a snapshot. Checks every domain first; one bad domain = nothing changes.
function import_all(array $snap): int {
    if (($snap['format'] ?? '') !== 'registrar-snapshot-1') fail('not a registrar snapshot');
    $tlds = [];
    foreach ($snap['tlds'] ?? [] as $t) { if (!is_string($t) || !valid_label($t)) fail("bad TLD in snapshot"); $tlds[] = $t; }
    $rows = [];
    foreach ($snap['domains'] ?? [] as $d) {
        $l = (string)($d['label'] ?? ''); $t = (string)($d['tld'] ?? '');
        if (!valid_label($l) || !in_array($t, $tlds, true)) fail("bad domain in snapshot: $l.$t");
        [$rec, $e] = validate_records($d, "$l.$t");
        if ($e) fail("$l.$t: " . implode(' ', $e));
        $rows[] = array_merge($rec, [
            'label' => $l, 'tld' => $t,
            'registrant' => mb_substr((string)($d['registrant'] ?? 'Range Admin'), 0, 100),
            'email' => mb_substr((string)($d['email'] ?? ''), 0, 100),
            'org' => mb_substr((string)($d['org'] ?? ''), 0, 100),
            'code_hash' => (string)($d['code_hash'] ?? ''),
            'status' => ($d['status'] ?? 'active') === 'active' ? 'active' : (string)$d['status'],
        ]);
    }
    $db = db();
    $db->beginTransaction();
    $db->exec('DELETE FROM domains'); $db->exec('DELETE FROM tlds');
    $addTld = $db->prepare('INSERT INTO tlds (name) VALUES (?)');
    foreach ($tlds as $t) $addTld->execute([$t]);
    $add = $db->prepare('INSERT INTO domains (label,tld,mode,ns1,ns1_ip,ns2,ns2_ip,a_ip,registrant,email,org,code_hash,status)
                         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)');
    foreach ($rows as $r) $add->execute([$r['label'], $r['tld'], $r['mode'], $r['ns1'], $r['ns1_ip'], $r['ns2'], $r['ns2_ip'],
                                         $r['a_ip'], $r['registrant'], $r['email'], $r['org'], $r['code_hash'], $r['status']]);
    $db->commit();
    set_setting('open_registration', ($snap['open_registration'] ?? '1') === '0' ? '0' : '1');
    return count($rows);
}
