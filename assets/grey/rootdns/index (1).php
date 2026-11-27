<?php
// Protected by Apache Basic auth (see /etc/apache2/sites-available/registrar.conf)
require __DIR__ . '/../../lib.php';

$flash = []; $errs = []; $applyOut = null;
$tlds = tlds();

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();
    $a = $_POST['action'] ?? ''; $id = (int)($_POST['id'] ?? 0); $needApply = true;
    switch ($a) {
        case 'add_tld':
            $t = strtolower(trim($_POST['tld'] ?? '', " .\t"));
            $ext = @file_get_contents('/etc/bind/zones/root.delegations') ?: '';
            if (!valid_label($t)) { $errs[] = 'Invalid TLD.'; $needApply = false; }
            elseif (preg_match('/^' . preg_quote($t, '/') . '\.\s+\d+\s+IN\s+NS/mi', $ext)) { $errs[] = ".$t is already delegated via add-tld.sh."; $needApply = false; }
            else { db()->prepare('INSERT OR IGNORE INTO tlds (name) VALUES (?)')->execute([$t]); $flash[] = "Added .$t"; }
            break;
        case 'del_tld':
            $t = $_POST['tld'] ?? '';
            $n = db()->prepare('SELECT COUNT(*) FROM domains WHERE tld = ?'); $n->execute([$t]);
            if ($n->fetchColumn() > 0 && empty($_POST['force'])) { $errs[] = ".$t still has domains — tick “delete domains too”."; $needApply = false; }
            else { db()->prepare('DELETE FROM domains WHERE tld = ?')->execute([$t]); db()->prepare('DELETE FROM tlds WHERE name = ?')->execute([$t]); $flash[] = "Removed .$t"; }
            break;
        case 'toggle_open':
            set_setting('open_registration', setting('open_registration', '1') === '1' ? '0' : '1'); $needApply = false;
            break;
        case 'suspend': case 'unsuspend':
            db()->prepare('UPDATE domains SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?')->execute([$a === 'suspend' ? 'suspended' : 'active', $id]);
            $flash[] = ucfirst($a) . 'ed.';
            break;
        case 'delete':
            db()->prepare('DELETE FROM domains WHERE id = ?')->execute([$id]); $flash[] = 'Domain deleted.';
            break;
        case 'reset_code':
            $code = gen_code();
            db()->prepare('UPDATE domains SET code_hash = ? WHERE id = ?')->execute([password_hash($code, PASSWORD_DEFAULT), $id]);
            $flash[] = "New management code: $code"; $needApply = false;
            break;
        case 'register':   // admin registration — reserved names allowed, no contact checks
            $label = strtolower(trim($_POST['label'] ?? '')); $t = $_POST['tld'] ?? '';
            [$rec, $e] = validate_records($_POST, "$label.$t");
            if (!valid_label($label) || !in_array($t, $tlds, true)) $e[] = 'Bad name or TLD.';
            if (find_domain($label, $t)) $e[] = "$label.$t already exists.";
            if ($e) { $errs = $e; $needApply = false; break; }
            $code = gen_code();
            db()->prepare('INSERT INTO domains (label,tld,mode,ns1,ns1_ip,ns2,ns2_ip,a_ip,registrant,org,code_hash) VALUES (?,?,?,?,?,?,?,?,?,?,?)')
              ->execute([$label, $t, $rec['mode'], $rec['ns1'], $rec['ns1_ip'], $rec['ns2'], $rec['ns2_ip'], $rec['a_ip'],
                         trim($_POST['registrant'] ?? '') ?: 'Range Admin', trim($_POST['org'] ?? ''), password_hash($code, PASSWORD_DEFAULT)]);
            $flash[] = "Registered $label.$t — management code: $code";
            break;
        case 'apply': break;
        default: $needApply = false;
    }
    if ($needApply) { [$ok, $applyOut] = apply_changes(); if (!$ok) $errs[] = 'Publishing to DNS failed — see output below.'; }
    $tlds = tlds();
}

function soa_serial(string $ip, string $zone): string {
    $o = trim((string)shell_exec('dig +short +norec +time=1 +tries=1 @' . escapeshellarg($ip) . ' ' . escapeshellarg($zone) . ' SOA 2>/dev/null'));
    $p = preg_split('/\s+/', $o);
    return (count($p) >= 3 && ctype_digit($p[2])) ? $p[2] : '—';
}
$r1 = cfg('root1_ip', ''); $r2 = cfg('root2_ip', '');
$open = setting('open_registration', '1') === '1';
$q = trim($_GET['q'] ?? '');
$sql = 'SELECT * FROM domains' . ($q !== '' ? " WHERE (label || '.' || tld) LIKE ? OR registrant LIKE ? OR org LIKE ?" : '') . ' ORDER BY tld, label';
$st = db()->prepare($sql); $st->execute($q !== '' ? array_fill(0, 3, "%$q%") : []); $domains = $st->fetchAll();

page_head('Admin', 'Admin'); ?>
<h1>Registrar admin</h1>
<?php foreach ($flash as $f): ?><div class="alert okmsg"><?= h($f) ?></div><?php endforeach; ?>
<?= errors_box($errs) ?>
<?php if ($applyOut !== null): ?><details class="card"<?= $errs ? ' open' : '' ?>><summary>registrar-apply output</summary><pre><?= h($applyOut) ?></pre></details><?php endif; ?>

<section class="card">
  <h2>Zone sync</h2>
  <table><tr><th>Zone</th><th><?= h(cfg('root1_name')) ?> (<?= h($r1) ?>)</th><th><?= h(cfg('root2_name')) ?> (<?= h($r2) ?>)</th><th></th></tr>
  <?php foreach (array_merge(['.'], $tlds) as $z): $a = soa_serial($r1, $z); $b = soa_serial($r2, $z); ?>
    <tr><td><?= $z === '.' ? '<strong>. (root)</strong>' : '.' . h($z) ?></td><td><code><?= h($a) ?></code></td><td><code><?= h($b) ?></code></td>
        <td><?= ($a !== '—' && $a === $b) ? '<span class="tag free">in sync</span>' : '<span class="tag taken">check</span>' ?></td></tr>
  <?php endforeach; ?></table>
  <form method="post" class="inline"><?= csrf_field() ?><input type="hidden" name="action" value="apply"><button class="btn sm">Re-publish now</button></form>
  <form method="post" class="inline"><?= csrf_field() ?><input type="hidden" name="action" value="toggle_open">
    <button class="btn sm <?= $open ? 'red' : '' ?>"><?= $open ? 'Close registration' : 'Open registration' ?></button></form>
  <span class="muted">Registration is <strong><?= $open ? 'open' : 'closed' ?></strong>.</span>
</section>

<section class="card">
  <h2>TLDs</h2>
  <table><?php foreach ($tlds as $t): ?>
    <tr><td>.<?= h($t) ?></td><td>
      <form method="post" class="inline" onsubmit="return confirm('Remove .<?= h($t) ?>?')"><?= csrf_field() ?>
        <input type="hidden" name="action" value="del_tld"><input type="hidden" name="tld" value="<?= h($t) ?>">
        <label class="chk"><input type="checkbox" name="force" value="1"> delete domains too</label> <button class="btn sm red">Remove</button></form></td></tr>
  <?php endforeach; ?></table>
  <form method="post" class="inline"><?= csrf_field() ?><input type="hidden" name="action" value="add_tld">
    <input name="tld" placeholder="new TLD, e.g. corp" required> <button class="btn sm">Add TLD</button></form>
</section>

<section class="card">
  <h2>Domains (<?= count($domains) ?>)</h2>
  <form method="get" class="search"><input name="q" value="<?= h($q) ?>" placeholder="filter by name, registrant, team"><button>Filter</button></form>
  <table><tr><th>Domain</th><th>Records</th><th>Registrant</th><th>Status</th><th></th></tr>
  <?php foreach ($domains as $d): ?>
    <tr class="<?= $d['status'] !== 'active' ? 'dim' : '' ?>">
      <td><a href="/whois.php?q=<?= h(urlencode($d['label'] . '.' . $d['tld'])) ?>"><?= h($d['label'] . '.' . $d['tld']) ?></a></td>
      <td><code><?= h(records_summary($d)) ?></code></td>
      <td><?= h($d['registrant']) ?><?= $d['org'] ? ' <span class="muted">(' . h($d['org']) . ')</span>' : '' ?></td>
      <td><?= h($d['status']) ?></td>
      <td class="actions">
        <?php foreach (($d['status'] === 'active' ? ['suspend' => 'Suspend'] : ['unsuspend' => 'Unsuspend']) + ['reset_code' => 'Reset code', 'delete' => 'Delete'] as $act => $lbl): ?>
          <form method="post" class="inline"<?= $act === 'delete' ? ' onsubmit="return confirm(\'Delete?\')"' : '' ?>><?= csrf_field() ?>
            <input type="hidden" name="action" value="<?= $act ?>"><input type="hidden" name="id" value="<?= (int)$d['id'] ?>">
            <button class="btn sm <?= $act === 'delete' ? 'red' : 'ghost' ?>"><?= $lbl ?></button></form>
        <?php endforeach; ?>
      </td></tr>
  <?php endforeach; ?></table>
</section>

<section class="card">
  <h2>Register as admin</h2>
  <p class="muted">Bypasses reserved names and the open/closed switch.</p>
  <form method="post" data-mode><?= csrf_field() ?><input type="hidden" name="action" value="register">
    <div class="domain-input"><input name="label" placeholder="name" required>
      <select name="tld"><?php foreach ($tlds as $t): ?><option><?= h($t) ?></option><?php endforeach; ?></select></div>
    <?= records_fields(['mode' => 'a']) ?>
    <div class="grid2"><label>Registrant<input name="registrant" placeholder="Range Admin"></label><label>Team / org<input name="org"></label></div>
    <button class="btn">Register</button>
  </form>
</section>
<?php page_foot();
