# range

Build a cyber range on Proxmox: a small fake internet, pods to defend, attackers and a scoring cell.

> **This repo is the build you deploy:** scripts, configs and guides. For a list of hardware, software and other resources worth knowing about, see [awesome-cyber-range](https://github.com/direwolfsecurity/awesome-cyber-range).

| Folder | What |
|---|---|
| `assets/grey/` | The fake internet: root and public DNS, time (`grey/time/`, a GPS-fed Pi), certificate authority, whois, GeoIP, maps, mirrors |
| `assets/blue/` | What students defend: domain controllers, workstations, DMZ web servers |
| `assets/red/` | Attack tooling and red team infrastructure |
| `assets/white/` | Scoring and exercise control (hooks for [ForgeRange](https://github.com/direwolfsecurity/forgerange)), syslog, monitoring |
| `docs/` | Range-wide documents |
| `network/` | List your students in `student-list.csv` and `gencfg.py` builds the configs. `network/devices/` has our own Cisco core and edge configs. |

Each asset folder has a `README.md`, `config/`, `build/` and `docs/`. See `assets/README.md`.

## Get one asset onto a VM

Each VM needs only its own asset folder, not the whole repo. Clone just that folder:

```
git clone --depth 1 --filter=blob:none --sparse https://github.com/direwolfsecurity/range.git
cd range
git sparse-checkout set <asset path>
cd <asset path>
```

For example, `<asset path>` is `assets/grey/maps` on the map server. You also get the license and README files above it,
which are small. Keep the folder on the VM after the build, and run `git pull` inside `range` to get updates.
Already cloned the whole repo? Run `git sparse-checkout set <asset path>` inside `range` to trim it.

**Status:** early. The grey cell is built first. Check each asset's README for what works.

## Ground rules

- No passwords in any file. Configs use placeholders; you fill them locally.
- No real malware, ever.
- Offensive work runs only on an air-gapped range.
- VM images are not in this repo. Build scripts make them.

Build scripts are written with AI assistance, reviewed by Tim Rosenberg and tested on real hardware.

## License

- **Guides, docs, diagrams and other content:** [CC BY-SA 4.0](LICENSE).
- **Code and scripts:** [GPL-3.0](LICENSE-CODE).

Use it in your class, change it, share it, even in something you sell. Two conditions: credit "Dire Wolf Security / Tim Rosenberg",
and release your changed version under the same license so it stays free for the next person.

## About Dire Wolf Security

Dire Wolf Security is a **fictional company**, made up for teaching. It is not a registered business.
It sells nothing, offers no services and is not tied to any school, employer or real company.
Any resemblance to a real organization is a coincidence.

The content is real, though: written by Tim Rosenberg, free to use, copy and change.

Views are my own (Tim Rosenberg), not those of any school, employer or other organization.
