<?php
// Range Registrar — shared library. Lives OUTSIDE the web root (/opt/registrar).
// License: GPL-3.0, Dire Wolf Security.
declare(strict_types=1);

const REG_INI = '/etc/registrar/registrar.ini';

function cfg(string $k, ?string $d = null): ?string {
    static $c = null;
    if ($c === null) { $c = @parse_ini_file(REG_INI) ?: []; }
    return isset($c[$k]) ? (string)$c[$k] : $d;
}

function db(): PDO {
    static $p = null;
    if ($p) return $p;
    $p = new PDO('sqlite:' . cfg('db_path', '/var/lib/registrar/registrar.db'));
    $p->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $p->setAttribute(PDO::ATTR_DEFAULT_FETCH_MODE, PDO::FETCH_ASSOC);
    $p->exec('PRAGMA busy_timeout = 5000');
    $p->exec("CREATE TABLE IF NOT EXISTS tlds (
        name TEXT PRIMARY KEY, created_at TEXT DEFAULT CURRENT_TIMESTAMP)");
    $p->exec("CREATE TABLE IF NOT EXISTS domains (
        id INTEGER PRIMARY KEY, label TEXT NOT NULL, tld TEXT NOT NULL,
        mode TEXT NOT NULL CHECK (mode IN ('ns','a')),
        ns1 TEXT, ns1_ip TEXT, ns2 TEXT, ns2_ip TEXT, a_ip TEXT,
        registrant TEXT, email TEXT, org TEXT, code_hash TEXT,
        status TEXT NOT NULL DEFAULT 'active',
        created_at TEXT DEFAULT CURRENT_TIMESTAMP, updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        UNIQUE (label, tld))");
    $p->exec("CREATE TABLE IF NOT EXISTS settings (k TEXT PRIMARY KEY, v TEXT)");
    return $p;
}

function setting(string $k, string $d = ''): string {
    $s = db()->prepare('SELECT v FROM settings WHERE k = ?'); $s->execute([$k]);
    $v = $s->fetchColumn(); return $v === false ? $d : (string)$v;
}
function set_setting(string $k, string $v): void {
    db()->prepare('INSERT INTO settings (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v')->execute([$k, $v]);
}

function h($s): string { return htmlspecialchars((string)$s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }

// ---------- validation ----------
function valid_label(string $l): bool { return (bool)preg_match('/^(?!-)[a-z0-9-]{1,63}(?<!-)$/', $l); }
function valid_host(string $h): bool {
    $h = rtrim(strtolower(trim($h)), '.');
    if ($h === '' || strlen($h) > 253) return false;
    $parts = explode('.', $h);
    if (count($parts) < 2) return false;
    foreach ($parts as $p) if (!valid_label($p)) return false;
    return true;
}
function valid_ip(string $ip): bool { return filter_var(trim($ip), FILTER_VALIDATE_IP) !== false; }
function norm_host(string $h): string { return rtrim(strtolower(trim($h)), '.'); }
function in_domain(string $host, string $fqdn): bool { return $host === $fqdn || str_ends_with($host, '.' . $fqdn); }

function tlds(): array { return db()->query('SELECT name FROM tlds ORDER BY name')->fetchAll(PDO::FETCH_COLUMN); }

function is_reserved(string $label, string $tld): bool {
    $res = array_filter(array_map('trim', explode(',', cfg('reserved', 'nic,whois,registry,localhost'))));
    if (in_array($label, $res, true)) return true;
    foreach ([cfg('root1_name', ''), cfg('root2_name', '')] as $rn) {     // e.g. root-servers.net
        if ($rn && in_domain(norm_host($rn), "$label.$tld")) return true;
    }
    return false;
}

function split_fqdn(string $q): array {           // "Foo.Com." -> ['foo','com']
    $q = norm_host($q);
    $pos = strpos($q, '.');
    return $pos === false ? [$q, ''] : [substr($q, 0, $pos), substr($q, $pos + 1)];
}

/** Validate the record fields (mode / NS / glue / A). Returns [data, errors]. */
function validate_records(array $in, string $fqdn): array {
    $e = []; $mode = ($in['mode'] ?? 'ns') === 'a' ? 'a' : 'ns';
    $d = ['mode' => $mode, 'ns1' => null, 'ns1_ip' => null, 'ns2' => null, 'ns2_ip' => null, 'a_ip' => null];
    if ($mode === 'a') {
        $ip = trim($in['a_ip'] ?? '');
        if (!valid_ip($ip)) $e[] = 'Enter a valid IP address for the A record.';
        $d['a_ip'] = $ip;
    } else {
        foreach (['ns1', 'ns2'] as $i => $k) {
            $host = norm_host($in[$k] ?? ''); $ip = trim($in[$k . '_ip'] ?? '');
            if ($host === '') { if ($k === 'ns1') $e[] = 'Nameserver 1 is required.'; continue; }
            if (!valid_host($host)) { $e[] = "Nameserver " . ($i + 1) . " is not a valid hostname."; continue; }
            if (in_domain($host, $fqdn)) {
                if (!valid_ip($ip)) $e[] = "$host is inside $fqdn, so it needs a glue IP address.";
            } else { $ip = ''; }                 // glue only meaningful in-bailiwick
            $d[$k] = $host; $d[$k . '_ip'] = $ip ?: null;
        }
        if ($d['ns1'] && $d['ns1'] === $d['ns2']) { $d['ns2'] = $d['ns2_ip'] = null; }
    }
    return [$d, $e];
}

function validate_contact(array $in): array {
    $e = [];
    $c = ['registrant' => trim($in['registrant'] ?? ''), 'email' => trim($in['email'] ?? ''), 'org' => trim($in['org'] ?? '')];
    if ($c['registrant'] === '') $e[] = 'Registrant name is required.';
    foreach ($c as $k => $v) if (mb_strlen($v) > 100) $e[] = ucfirst($k) . ' is too long.';
    return [$c, $e];
}

function gen_code(): string {
    $a = 'abcdefghjkmnpqrstuvwxyz23456789';
    $s = ''; for ($i = 0; $i < 12; $i++) { $s .= $a[random_int(0, strlen($a) - 1)]; if ($i % 4 === 3 && $i < 11) $s .= '-'; }
    return $s;
}

function find_domain(string $label, string $tld): ?array {
    $s = db()->prepare('SELECT * FROM domains WHERE label = ? AND tld = ?'); $s->execute([$label, $tld]);
    return $s->fetch() ?: null;
}

/** Push DB state into BIND (via the one sudo-allowed helper). */
function apply_changes(): array {
    $out = []; $rc = 0;
    exec('sudo -n /usr/local/sbin/registrar-apply 2>&1', $out, $rc);
    return [$rc === 0, implode("\n", $out)];
}

function records_summary(array $d): string {
    if ($d['mode'] === 'a') return 'A ' . $d['a_ip'];
    $ns = array_filter([$d['ns1'], $d['ns2']]);
    return 'NS ' . implode(', ', $ns);
}

// ---------- session / csrf ----------
function sess(): void { if (session_status() !== PHP_SESSION_ACTIVE) { session_start(['cookie_httponly' => true, 'cookie_samesite' => 'Strict']); } }
function csrf_token(): string { sess(); return $_SESSION['csrf'] ??= bin2hex(random_bytes(16)); }
function csrf_field(): string { return '<input type="hidden" name="csrf" value="' . h(csrf_token()) . '">'; }
function check_csrf(): void {
    sess();
    if (!hash_equals($_SESSION['csrf'] ?? '', (string)($_POST['csrf'] ?? ''))) { http_response_code(400); exit('Bad request (form expired — go back and reload).'); }
}

// ---------- layout ----------
function page_head(string $title, string $active = ''): void {
    $site = cfg('title', 'Range Registrar');
    $nav = ['/' => 'Register', '/whois.php' => 'Whois', '/manage.php' => 'Manage', '/admin/' => 'Admin'];
    echo '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">';
    echo '<title>' . h($title) . ' · ' . h($site) . '</title><link rel="stylesheet" href="/style.css"></head><body>';
    echo '<header><div class="wrap"><a class="brand" href="/">' . h($site) . '</a><nav>';
    foreach ($nav as $href => $label) echo '<a href="' . $href . '"' . ($active === $label ? ' class="on"' : '') . '>' . $label . '</a>';
    echo '</nav></div></header><main class="wrap">';
}
function page_foot(): void {
    echo '</main><footer class="wrap">Cyber range registrar · TLDs: ' . h(implode(' ', array_map(fn($t) => ".$t", tlds()))) . '</footer>';
    echo '<script>document.querySelectorAll("[data-mode]").forEach(f=>{const s=()=>{const m=f.querySelector("input[name=mode]:checked")?.value;f.querySelectorAll("[data-show]").forEach(x=>x.hidden=x.dataset.show!==m)};f.addEventListener("change",s);s()});</script>';
    echo '</body></html>';
}

function errors_box(array $errs): string {
    if (!$errs) return '';
    return '<div class="alert err"><ul>' . implode('', array_map(fn($e) => '<li>' . h($e) . '</li>', $errs)) . '</ul></div>';
}

/** Records form fragment (used by register, manage, admin). */
function records_fields(array $v, string $fqdn_hint = 'yourname.com'): string {
    $mode = ($v['mode'] ?? 'ns') === 'a' ? 'a' : 'ns';
    $g = fn($k) => h($v[$k] ?? '');
    return '
    <fieldset class="modes"><legend>How should this domain resolve?</legend>
      <label><input type="radio" name="mode" value="ns"' . ($mode === 'ns' ? ' checked' : '') . '> Use my own DNS servers</label>
      <label><input type="radio" name="mode" value="a"' . ($mode === 'a' ? ' checked' : '') . '> Simple: point it at one IP</label>
    </fieldset>
    <div data-show="ns" class="grid2">
      <label>Nameserver 1<input name="ns1" value="' . $g('ns1') . '" placeholder="ns1.' . h($fqdn_hint) . '"></label>
      <label>Glue IP <small>(only if NS is inside your domain)</small><input name="ns1_ip" value="' . $g('ns1_ip') . '" placeholder="10.x.x.x"></label>
      <label>Nameserver 2 <small>(optional)</small><input name="ns2" value="' . $g('ns2') . '"></label>
      <label>Glue IP<input name="ns2_ip" value="' . $g('ns2_ip') . '"></label>
    </div>
    <div data-show="a" class="grid2">
      <label>IP address<input name="a_ip" value="' . $g('a_ip') . '" placeholder="10.x.x.x"></label>
      <p class="hint">Creates <code>' . h($fqdn_hint) . '</code> and <code>www.' . h($fqdn_hint) . '</code>.</p>
    </div>';
}
