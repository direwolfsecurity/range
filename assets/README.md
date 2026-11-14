# Assets

Everything that runs on the range lives here, sorted by the cell that owns it.

| Folder | Cell | What goes here |
|---|---|---|
| `grey\` | Grey | The fake internet: DNS, time, certificates, maps, registry, mirrors. Neither team controls these. |
| `blue\` | Blue | What students defend: pod domain controllers, workstations, DMZ web servers. |
| `red\` | Red | Attack tooling: Kali builds, red team infrastructure, attack playbooks. |
| `white\` | White | Scoring and exercise control: ForgeRange hooks, syslog, monitoring. Off-limits to both teams. |

## One folder per asset

Each asset gets its own folder inside its cell, named in lowercase with hyphens (for example `grey\root-dns\`).
Create the folder when the build starts, not before.

| Inside the asset folder | What |
|---|---|
| `README.md` | What it is, its address, how to build it, how to test it. |
| `config\` | Config files and templates. Placeholders only, no passwords. |
| `build\` | Build and install scripts. Scripts run in test mode unless given `-Go`. |
| `docs\` | Diagrams, notes and anything longer than the README. |

## Rules

- VM disk images do not go here. They go in `..\vms\` (not published).
- No passwords in any file. `network\configs\Set-Secrets.ps1` fills placeholders into `_ready\`.
- Files we may not republish (ISOs, map data, vendor downloads) are linked to their source or fetched by a script.
- Addresses come from `network\` CSVs. Do not hand-type an address into two places.
