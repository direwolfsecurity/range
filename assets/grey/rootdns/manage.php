<?php
require __DIR__ . '/../lib.php';
sess();

$errs = []; $msg = null; $dom = null;

// ---- log in with domain + management code ----
if (($_POST['action'] ?? '') === 'login') {
    check_csrf();
    [$l, $t] = split_fqdn($_POST['domain'] ?? '');
    $d = ($l && $t) ? find_domain($l, $t) : null;
    if ($d && password_verify(trim($_POST['code'] ?? ''), (string)$d['code_hash'])) {
        $_SESSION['manage'][$d['id']] = true;
        header('Location: /manage.php?d=' . $d['id']); exit;
    }
    usleep(500000);
    $errs[] = 'Domain or management code is wrong.';
}

$id = (int)($_GET['d'] ?? 0);
if ($id && !empty($_SESSION['manage'][$id])) {
    $s = db()->prepare('SELECT * FROM domains WHERE id = ?'); $s->execute([$id]); $dom = $s->fetch() ?: null;
    if (!$dom) unset($_SESSION['manage'][$id]);
}

if ($dom && $_SERVER['REQUEST_METHOD'] === 'POST' && in_array($_POST['action'] ?? '', ['update', 'delete'], true)) {
    check_csrf();
    $fqdn = $dom['label'] . '.' . $dom['tld'];
    if ($dom['status'] !== 'active') {
        $errs[] = 'This domain is suspended — contact the registrar (instructor).';
    } elseif ($_POST['action'] === 'delete') {
        db()->prepare('DELETE FROM domains WHERE id = ?')->execute([$id]);
        [$ok, $out] = apply_changes();
        unset($_SESSION['manage'][$id]);
        page_head('Deleted', 'Manage');
        echo '<section class="card"><h1>' . h($fqdn) . ' deleted</h1><p>The name is available again.</p>'
           . ($ok ? '' : '<div class="alert err">DNS publish failed:<pre>' . h($out) . '</pre></div>') . '</section>';
        page_foot(); exit;
    } else {
        [$rec, $errs] = validate_records($_POST, $fqdn);
        if (!$errs) {
            db()->prepare("UPDATE domains SET mode=?, ns1=?, ns1_ip=?, ns2=?, ns2_ip=?, a_ip=?, updated_at=CURRENT_TIMESTAMP WHERE id=?")
                ->execute([$rec['mode'], $rec['ns1'], $rec['ns1_ip'], $rec['ns2'], $rec['ns2_ip'], $rec['a_ip'], $id]);
            [$ok, $out] = apply_changes();
            $msg = $ok ? 'Saved and published.' : "Saved, but publishing failed:\n$out";
            $s = db()->prepare('SELECT * FROM domains WHERE id = ?'); $s->execute([$id]); $dom = $s->fetch();
        }
    }
}

page_head('Manage domain', 'Manage');

if (!$dom): ?>
  <section class="card narrow">
    <h1>Manage a domain</h1>
    <?= errors_box($errs) ?>
    <form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="login">
      <label>Domain<input name="domain" placeholder="acme.com" required value="<?= h($_POST['domain'] ?? '') ?>"></label>
      <label>Management code<input name="code" placeholder="xxxx-xxxx-xxxx" required autocomplete="off"></label>
      <button class="btn">Continue</button>
    </form>
    <p class="muted">Lost your code? The instructor can reset it from the admin page.</p>
  </section>
<?php else: $fqdn = $dom['label'] . '.' . $dom['tld']; ?>
  <section class="card">
    <h1><?= h($fqdn) ?> <?php if ($dom['status'] !== 'active'): ?><span class="tag taken">suspended</span><?php endif; ?></h1>
    <?php if ($msg): ?><div class="alert <?= str_starts_with($msg, 'Saved and') ? 'okmsg' : 'err' ?>"><pre><?= h($msg) ?></pre></div><?php endif; ?>
    <?= errors_box($errs) ?>
    <form method="post" data-mode><?= csrf_field() ?><input type="hidden" name="action" value="update">
      <?= records_fields(array_merge($dom, $_POST), $fqdn) ?>
      <button class="btn">Save changes</button>
    </form>
  </section>
  <section class="card danger">
    <h2>Delete domain</h2>
    <form method="post" onsubmit="return confirm('Delete <?= h($fqdn) ?>? Anyone can register it afterwards.')">
      <?= csrf_field() ?><input type="hidden" name="action" value="delete"><button class="btn red">Delete <?= h($fqdn) ?></button>
    </form>
  </section>
<?php endif;
page_foot();
