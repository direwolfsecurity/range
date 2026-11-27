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
// Then publish: sudo registrar-apply
require __DIR__ . '/lib.php';
if (PHP_SAPI !== 'cli') exit;

$cmd = $argv[1] ?? ''; $args = array_slice($argv, 2);
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
        insert($l, $t, $rec); break;
    case 'add-ns':
        [$l, $t] = need_dom($args[0] ?? '');
        [$rec, $e] = validate_records(['mode' => 'ns', 'ns1' => $args[1] ?? '', 'ns1_ip' => $args[2] ?? '', 'ns2' => $args[3] ?? '', 'ns2_ip' => $args[4] ?? ''], "$l.$t");
        if ($e) fail(implode(' ', $e)); insert($l, $t, $rec); break;
    case 'del':
        [$l, $t] = need_dom($args[0] ?? '');
        db()->prepare('DELETE FROM domains WHERE label = ? AND tld = ?')->execute([$l, $t]); echo "deleted $l.$t\n"; break;
    case 'list':
        echo 'TLDs: ' . implode(' ', tlds()) . '   registration: ' . (setting('open_registration', '1') === '1' ? 'open' : 'closed') . "\n";
        foreach (db()->query('SELECT * FROM domains ORDER BY tld, label') as $d)
            printf("  %-32s %-9s %-40s %s\n", "$d[label].$d[tld]", $d['status'], records_summary($d), $d['registrant']);
        break;
    case 'open': case 'close':
        set_setting('open_registration', $cmd === 'open' ? '1' : '0'); echo "registration $cmd\n"; break;
    default:
        echo implode("\n", array_slice(file(__FILE__, FILE_IGNORE_NEW_LINES), 1, 11)), "\n"; exit(1);
}
