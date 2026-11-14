# White cell assets

White assets run and score the exercise. They live on VLAN 120 (WHITECELL, 172.16.12.0/24) and are off-limits to both teams.
One folder per asset; see `..\README.md` for the layout.

ForgeRange code is not kept here. It is written by Tim alone and lives in its own repo.
This folder holds only how the range deploys and connects to it.

Expected here (none started):

- ForgeRange scoring host (.20) and database (.21): deployment notes only
- Syslog collector (.30), which also takes DNS query logs from the grey cell
- Monitoring and exercise-control tools

No asset list has been agreed yet.
