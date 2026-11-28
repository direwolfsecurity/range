# Range control server (greyctl): one place to change the fake internet

This builds the range control server on an Ubuntu Server 24.04 VM or container. No Docker.
It changes the grey cell (the fake internet) from one place, in two ways that do exactly the same thing:

- **By hand, while teaching:** the `greyctl` command.
- **From ForgeRange, during an exercise:** an HTTPS API with a token. Every API call runs the same code as a `greyctl` command.

It is a white cell asset: off-limits to both teams. During an exercise the grey cell is in scope, so the server
that controls it lives on WHITECELL, where the core's `WHITE-PROTECT` list keeps everyone else out.

License: CC BY-SA 4.0 for this guide, GPL-3.0 for the scripts. Dire Wolf Security.

## What it does

| Job | Command | What changes on the range |
|---|---|---|
| Add a team | `greyctl team add blue1 --network 192.168.103.0/24 --org "Kestrel Freight" --domain kestrel.lab --a 192.168.103.1` | The seat network gets a new owner, AS number, place on the map and domain. GeoIP, whois and DNS all agree. |
| Remove a team | `greyctl team del blue1` | The seat goes back to what `registry.csv` says. |
| Add a domain | `greyctl domain add kestre1.lab --a 172.16.13.50` | A domain on the registrar that is not tied to a team, for example a look-alike for a phishing lab. |
| Clear an exercise | `greyctl exercise clear ev7` | Every team and domain added with `--exercise ev7` is removed. |
| Snapshot | `greyctl snapshot save before-lab4` | Saves the whole fake internet: teams, domains, and every domain on the registrar, students' own included. |
| Go back | `greyctl snapshot restore before-lab4` | Puts it all back the way it was. |
| Reset to zero | `greyctl reset` | Restores the snapshot called `zero`: the clean core you saved once, right after building it. |
| Look up | `greyctl lookup 192.168.103.5` | Changes nothing. Shows the owner GeoIP and whois give for that address. |
| Check | `greyctl status` | Changes nothing. Shows teams, snapshots, and whether each grey server answers. |

`registry.csv` in git is never changed. Teams are kept in an **overlay**: a second list with the same columns that each
grey server lays over `registry.csv` when it rebuilds (see `network/registry/README.md`). Seat networks
(192.168.101-109 and 192.168.201-207) can be taken over by a team. The grey, white, red, transit, city and target networks
cannot, so an exercise can never break the core.

## Reset to zero: the start of a new year

The `zero` snapshot is the clean core: the same grey and white addresses, the infrastructure names on the registrar
(`ca.lab`, `mqtt.lab` ...), no teams, no student registrations. Save it once, when the core is built and checked:

```bash
greyctl snapshot save zero --note "clean core, 2026-12"
```

At the end of an exercise, a semester or the school year, `greyctl reset` puts the fake internet back to that point.
Seats keep their 192.168 addresses. If you add a grey server later, save `zero` again with `--replace`.

What a snapshot covers, and what it does not:

| Covered | Not covered (reset these their own way) |
|---|---|
| Exercise teams (GeoIP, whois and reverse DNS) | Certificates the CA has issued. They expire by themselves (90 days). |
| Exercise domains | MQTT logins (`assets/grey/mqtt/`, re-run its install) |
| Every domain on the registrar, students' own included, and whether registration is open | Student pods and VMs (Proxmox) |

## What you need

| Item | Notes |
|---|---|
| Ubuntu Server 24.04 VM or container | 1 CPU, 512 MB RAM, 4 GB disk. A static address. |
| Address | Planned: **172.16.12.40** on WHITECELL (VLAN 120). No name in the fake internet's DNS; ForgeRange uses the address. |
| The grey servers it controls | The registrar on root-a (built). GeoIP (`geoip-apply`), whois (`whois-apply`) and reverse DNS (`dns-apply`) once each is built. |
| Internet, for the first setup | Only if `openssh-client` or `ufw` are missing. |

## 1. Get the files

This asset reads the range registry, so clone both folders:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/direwolfsecurity/range.git
cd range
git sparse-checkout set assets/white/control network/registry
cd assets/white/control
```

## 2. Install

```bash
sudo bash install.sh          # test mode: lists what it will do, changes nothing
sudo bash install.sh --go     # does it, then checks
```

Settings are in `control.conf`: this server's address, how to reach each grey server, who may use the API.
It makes a `greyctl` user that owns the state, the snapshots and an SSH key, and a `greyctl-api` service.
After a `git pull` (for example a new `registry.csv`), run `--go` again.

## 3. Let it reach the grey servers

greyctl reaches each grey server over SSH with its own key. On each server, that key can run **one** command and nothing else,
and only from this server's address.

1. On root-a, add the registrar's remote command once (new registrar builds already have it):
   ```bash
   cd ~/range/assets/grey/root-dns/registrar && git pull && sudo bash install-remote.sh
   ```
   GeoIP, whois and reverse DNS install their own (`geoip-apply`, `whois-apply`, `dns-apply`) every time their `install.sh --go` runs.
2. On this server, print the lines to add:
   ```bash
   sudo bash install.sh --keys
   ```
3. Paste each line on its grey server. Set `REGISTRAR`, `GEOIP`, `WHOIS` and `DNS` in `control.conf`, then `sudo bash install.sh --go`.
4. `greyctl status` should say `ok` for each one.

## 4. HTTPS for the API

Make a certificate on the CA (`assets/grey/ca/`, step 5) and copy it here:

```bash
# on ca.lab
sudo bash install.sh --issue control.white.lab --san 172.16.12.40 --go
# copy /root/direwolf-ca-issued/control.white.lab/control.white.lab.crt and .key to this server, then:
sudo install -m 640 -o root -g greyctl control.white.lab.crt /etc/greyctl/tls/server.crt
sudo install -m 640 -o root -g greyctl control.white.lab.key /etc/greyctl/tls/server.key
sudo systemctl restart greyctl-api
```

Delete the copies on the CA afterwards. A hand-made certificate does not renew itself: write its end date down.

## 5. Tokens

```bash
greyctl token add forgerange exercise     # for ForgeRange
greyctl token add tim read                # for looking only
```

The token is shown once. Only its SHA-256 is kept. Store it outside git: ForgeRange keeps it in its `.env`.

| Scope | Can |
|---|---|
| `read` | Look: status, lookups, lists |
| `exercise` | Also add and remove teams and domains, clear an exercise, save and restore snapshots |
| `admin` | Also reset to zero, save or restore `zero`, delete snapshots |

## The API

Every request: `Authorization: Bearer <token>`. Answers are JSON. A change waits for the grey servers to finish, then answers.

| Call | Scope | What |
|---|---|---|
| `GET /v1/info` | read | Status of each grey server, teams, snapshots |
| `GET /v1/lookup?ip=192.168.103.5` | read | Who owns an address |
| `GET /v1/teams` | read | |
| `POST /v1/teams` | exercise | `{"name":"blue1","networks":["192.168.103.0/24"],"org":"Kestrel Freight","domain":"kestrel.lab","a":"192.168.103.1","exercise":"ev7"}`. Optional: `city` (any city in `registry.csv`; default is the seat's own), `ns` instead of `a` (`["ns1.kestrel.lab=192.168.103.10"]`) |
| `DELETE /v1/teams/NAME` | exercise | |
| `GET /v1/domains` | read | |
| `POST /v1/domains` | exercise | `{"name":"kestre1.lab","a":"172.16.13.50","exercise":"ev7"}` |
| `DELETE /v1/domains/NAME` | exercise | |
| `POST /v1/exercises/TAG/clear` | exercise | Remove every team and domain of one exercise |
| `POST /v1/apply` | exercise | Send everything to every grey server again |
| `GET /v1/snapshots` | read | |
| `POST /v1/snapshots` | exercise | `{"name":"before-ev7","note":"..."}` |
| `POST /v1/snapshots/NAME/restore` | exercise | |
| `DELETE /v1/snapshots/NAME` | admin | |
| `POST /v1/reset` | admin | Back to `zero` |

Example from a WHITECELL machine:

```bash
curl -s --cacert range-root.crt -H "Authorization: Bearer $TOKEN" https://172.16.12.40:8443/v1/lookup?ip=192.168.103.5
```

## Check it

```bash
sudo bash install.sh --check
greyctl status
```

Every change is written to `/var/lib/greyctl/changes.log` with who made it (`cli:tim`, `api:forgerange`), and to syslog.

## Files

| File | What |
|---|---|
| `greyctl.py` | The command and all the logic. Python standard library only. |
| `greyctl-api.py` | The HTTPS API. Calls the same functions. Standard library only. |
| `control.conf` | Settings. |
| `install.sh` | Install or update. Test mode unless given `--go`. |
| `tests/test_greyctl.py` | Tests with fake grey servers: `python3 -m unittest discover -s tests` |

On the server: program in `/opt/greyctl`, settings in `/etc/greyctl`, state, snapshots, tokens and the SSH key in
`/var/lib/greyctl`. **Back up `/var/lib/greyctl`**: the snapshots, including `zero`, live there.

## If something is wrong

| Problem | Fix |
|---|---|
| `greyctl status` says PROBLEM for a server | The SSH key line is missing on that server, or its address is wrong in `control.conf`. Test: `sudo -u greyctl ssh -i /var/lib/greyctl/.ssh/id_ed25519 root@<server> status`. |
| A change says "The change is saved here; fix that server" | One grey server failed. Fix it, then `greyctl apply` sends everything again. Running it twice is safe. |
| `there is no 'zero' snapshot yet` | Save one when the core is clean: `greyctl snapshot save zero`. |
| A team is refused: "not a team network" | Only seat networks (192.168.101-109, 201-207) or networks the registry does not use can be teams. |

## Status

Written 2026-11-28 and tested on a scratch Ubuntu machine (not on the range yet): the ten unit tests; `install.sh --go`
(with systemd and ufw stubbed); the real `registrar-remote` and `cli.php` over SSH with a locked key (a team added,
snapshot, reset to zero with a student's domain removed, restore); the API over HTTP and HTTPS with the three token scopes;
GeoIP's overlay check and a real database build from a merged registry. Not yet tested: GeoIP's full `install.sh --go` with an
overlay on geoip.lab, and ForgeRange calling the API (ForgeRange's client is not written yet).
Added 2026-11-28: whois (`whois-apply`) and reverse DNS (`dns-apply`), tested on a scratch machine with `cmd:` targets: a team
added, `greyctl status`, and reset to zero all reached both, and a PTR and a whois answer changed and came back.
