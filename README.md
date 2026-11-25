# range

Build a cyber range on Proxmox: a small fake internet, pods to defend, attackers and a scoring cell.

| Folder | What |
|---|---|
| `assets/grey/` | The fake internet: root and public DNS, time (`grey/time/`, a GPS-fed Pi), certificate authority, whois, GeoIP, maps, mirrors |
| `assets/blue/` | What students defend: domain controllers, workstations, DMZ web servers |
| `assets/red/` | Attack tooling and red team infrastructure |
| `assets/white/` | Scoring and exercise control (hooks for [ForgeRange](https://github.com/trosenberg-dev/forgerange)), syslog, monitoring |
| `docs/` | Range-wide documents |
| `network/` | Templates: list your students in `student-list.csv`, and the scripts build the configs (coming) |

Each asset folder has a `README.md`, `config/`, `build/` and `docs/`. See `assets/README.md`.

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
