<?php
require __DIR__ . '/../lib.php';

$q = trim($_GET['q'] ?? ''); $d = null;
if ($q !== '') { [$l, $t] = split_fqdn($q); if ($l && $t) $d = find_domain($l, $t); }

page_head('Whois', 'Whois'); ?>
<section class="card">
  <h1>Whois</h1>
  <form class="search" method="get"><input name="q" value="<?= h($q) ?>" placeholder="acme.com"><button>Look up</button></form>
  <?php if ($q !== '' && !$d): ?>
    <p>No match for <strong><?= h($q) ?></strong>.</p>
  <?php elseif ($d): $fqdn = $d['label'] . '.' . $d['tld']; ?>
<?php
    $rows = ['Domain Name' => strtoupper($fqdn), 'Registrar' => cfg('title', 'Range Registrar'), 'Status' => $d['status'],
             'Created' => $d['created_at'] . ' UTC', 'Updated' => $d['updated_at'] . ' UTC', 'Registrant' => $d['registrant'],
             'Organization' => $d['org'] ?: '-', 'Email' => $d['email'] ?: '-'];
    $out = '';
    foreach ($rows as $k => $val) $out .= str_pad("$k:", 18) . $val . "\n";
    if ($d['mode'] === 'ns') {
        foreach (['ns1', 'ns2'] as $k) if ($d[$k]) $out .= str_pad('Name Server:', 18) . strtoupper($d[$k]) . ($d[$k . '_ip'] ? "  (glue {$d[$k . '_ip']})" : '') . "\n";
    } else {
        $out .= str_pad('Name Server:', 18) . strtoupper(cfg('root1_name', '')) . "  (registrar-hosted)\n";
        $out .= str_pad('A record:', 18) . $d['a_ip'] . "\n";
    }
    echo '<pre class="whois">' . h($out) . '</pre>';
  ?>
  <?php endif; ?>
</section>
<section class="card">
  <h2>TLDs on offer</h2>
  <table><tr><th>TLD</th><th>Registered</th></tr>
  <?php foreach (db()->query("SELECT t.name, COUNT(d.id) n FROM tlds t LEFT JOIN domains d ON d.tld = t.name GROUP BY t.name ORDER BY t.name") as $r): ?>
    <tr><td>.<?= h($r['name']) ?></td><td><?= (int)$r['n'] ?></td></tr>
  <?php endforeach; ?></table>
</section>
<?php page_foot();
