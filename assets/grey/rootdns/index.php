<?php
require __DIR__ . '/../lib.php';

$tlds = tlds();
$errs = []; $done = null; $applyMsg = null;
$v = array_merge(['label' => '', 'tld' => $tlds[0] ?? '', 'mode' => 'ns'], $_GET, $_POST);
$open = setting('open_registration', '1') === '1';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();
    $label = strtolower(trim($_POST['label'] ?? ''));
    $tld   = strtolower(trim($_POST['tld'] ?? ''));
    $fqdn  = "$label.$tld";
    if (!$open) $errs[] = 'Registration is currently closed.';
    if (!in_array($tld, $tlds, true)) $errs[] = 'Pick a TLD from the list.';
    if (!valid_label($label)) $errs[] = 'Names use a–z, 0–9 and hyphens (not at the start or end), up to 63 characters.';
    elseif (is_reserved($label, $tld)) $errs[] = "$fqdn is reserved.";
    [$rec, $e1] = validate_records($_POST, $fqdn);
    [$con, $e2] = validate_contact($_POST);
    $errs = array_merge($errs, $e1, $e2);
    if (!$errs) {
        $code = gen_code();
        try {
            db()->prepare('INSERT INTO domains (label, tld, mode, ns1, ns1_ip, ns2, ns2_ip, a_ip, registrant, email, org, code_hash)
                           VALUES (?,?,?,?,?,?,?,?,?,?,?,?)')
                ->execute([$label, $tld, $rec['mode'], $rec['ns1'], $rec['ns1_ip'], $rec['ns2'], $rec['ns2_ip'], $rec['a_ip'],
                           $con['registrant'], $con['email'], $con['org'], password_hash($code, PASSWORD_DEFAULT)]);
            [$ok, $out] = apply_changes();
            $done = ['fqdn' => $fqdn, 'code' => $code, 'ok' => $ok, 'out' => $out, 'rec' => $rec];
        } catch (PDOException $ex) {
            $errs[] = str_contains($ex->getMessage(), 'UNIQUE') ? "$fqdn is already registered." : 'Database error.';
        }
    }
}

// ---- availability search ----
$q = trim($_GET['q'] ?? ''); $results = [];
if ($q !== '') {
    [$ql, $qt] = split_fqdn($q);
    $check = $qt !== '' ? [$qt] : $tlds;
    foreach ($check as $t) {
        if (!in_array($t, $tlds, true)) { $results[] = [$ql, $t, 'notld']; continue; }
        if (!valid_label($ql))        { $results[] = [$ql, $t, 'invalid']; continue; }
        if (is_reserved($ql, $t))     { $results[] = [$ql, $t, 'reserved']; continue; }
        $results[] = [$ql, $t, find_domain($ql, $t) ? 'taken' : 'free'];
    }
}

page_head('Register a domain', 'Register');

if ($done): ?>
  <section class="card ok">
    <h1><?= h($done['fqdn']) ?> is yours</h1>
    <p>Your <strong>management code</strong> is shown <strong>once</strong>. Save it — you need it to change or delete this domain.</p>
    <p class="code"><?= h($done['code']) ?></p>
    <p>Records: <code><?= h(records_summary($done['rec'])) ?></code></p>
    <?php if ($done['ok']): ?>
      <p class="muted">Published to the root servers. Resolvers may cache the old “doesn’t exist” answer for up to 5 minutes.</p>
    <?php else: ?>
      <div class="alert err">Saved, but publishing to DNS failed — tell your instructor.<pre><?= h($done['out']) ?></pre></div>
    <?php endif; ?>
    <p><a class="btn" href="/">Register another</a> <a class="btn ghost" href="/whois.php?q=<?= h(urlencode($done['fqdn'])) ?>">View whois</a></p>
  </section>
<?php else: ?>
  <section class="hero">
    <h1>Find your domain</h1>
    <form class="search" method="get">
      <input name="q" value="<?= h($q) ?>" placeholder="e.g. acme or acme.com" autofocus>
      <button>Search</button>
    </form>
    <?php if ($results): ?>
      <table class="results">
      <?php foreach ($results as [$l, $t, $st]): ?>
        <tr><td><strong><?= h("$l.$t") ?></strong></td><td>
        <?php switch ($st) {
            case 'free': echo '<span class="tag free">Available</span></td><td><a class="btn sm" href="?label=' . h(urlencode($l)) . '&tld=' . h(urlencode($t)) . '#register">Register</a>'; break;
            case 'taken': echo '<span class="tag taken">Taken</span></td><td><a href="/whois.php?q=' . h(urlencode("$l.$t")) . '">whois</a>'; break;
            case 'reserved': echo '<span class="tag taken">Reserved</span></td><td>'; break;
            case 'notld': echo '<span class="tag taken">.' . h($t) . ' not offered</span></td><td>'; break;
            default: echo '<span class="tag taken">Invalid name</span></td><td>';
        } ?></td></tr>
      <?php endforeach; ?>
      </table>
    <?php endif; ?>
  </section>

  <section class="card" id="register">
    <h2>Register</h2>
    <?php if (!$open): ?><div class="alert err">Registration is closed right now.</div><?php endif; ?>
    <?php if (!$tlds): ?><div class="alert err">No TLDs are on offer yet.</div><?php else: ?>
    <?= errors_box($errs) ?>
    <form method="post" data-mode>
      <?= csrf_field() ?>
      <div class="domain-input">
        <input name="label" value="<?= h($v['label']) ?>" placeholder="yourname" required pattern="[A-Za-z0-9-]{1,63}">
        <select name="tld"><?php foreach ($tlds as $t): ?><option<?= $t === $v['tld'] ? ' selected' : '' ?>><?= h($t) ?></option><?php endforeach; ?></select>
      </div>
      <?= records_fields($v) ?>
      <fieldset><legend>Registrant</legend><div class="grid3">
        <label>Name<input name="registrant" value="<?= h($v['registrant'] ?? '') ?>" required></label>
        <label>Team / org<input name="org" value="<?= h($v['org'] ?? '') ?>"></label>
        <label>Email<input name="email" value="<?= h($v['email'] ?? '') ?>"></label>
      </div></fieldset>
      <button class="btn" <?= $open ? '' : 'disabled' ?>>Register domain</button>
    </form>
    <?php endif; ?>
  </section>

  <section class="card">
    <h2>Recently registered</h2>
    <?php $recent = db()->query("SELECT * FROM domains WHERE status='active' ORDER BY id DESC LIMIT 15")->fetchAll(); ?>
    <?php if (!$recent): ?><p class="muted">Nothing yet — be the first.</p><?php else: ?>
    <table><tr><th>Domain</th><th>Records</th><th>Registrant</th><th>Since</th></tr>
    <?php foreach ($recent as $d): ?>
      <tr><td><a href="/whois.php?q=<?= h(urlencode($d['label'] . '.' . $d['tld'])) ?>"><?= h($d['label'] . '.' . $d['tld']) ?></a></td>
          <td><code><?= h(records_summary($d)) ?></code></td><td><?= h($d['org'] ?: $d['registrant']) ?></td><td><?= h(substr($d['created_at'], 0, 16)) ?></td></tr>
    <?php endforeach; ?></table>
    <?php endif; ?>
  </section>
<?php endif;
page_foot();
