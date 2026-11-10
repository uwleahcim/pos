# POS hub: installing a mini PC

A hub is a small fanless Linux PC in the restaurant that runs the whole POS backend for that location: the
API the terminals talk to, PostgreSQL, printing, and sync to the cloud. Two per location is the recommended
shape. This guide installs one; it takes about fifteen minutes, most of it downloads.

## Hardware

- A fanless mini PC, x86-64, 8 GB RAM, a 128 GB or larger SSD, wired gigabit Ethernet. About $300 to $500.
- Its own small UPS, shared with the switch and router. The two hubs of a location sit in different spots.
- For the phase 0 lab one hub is enough. The second hub and a Raspberry Pi witness come with the failover
  spike (`spikes/hub-failover`).

## 1. Operating system

Install Ubuntu Server, 24.04 LTS or 26.04 LTS. Download the ISO from ubuntu.com, write it to a USB stick with Rufus or
balenaEtcher, and boot the mini PC from the stick. In the installer:

- Keep the default "Ubuntu Server" (not minimized).
- Network: the wired port, DHCP. Afterwards give the hub a DHCP reservation on the router so its address
  never changes; that beats a static address typed into the hub.
- Storage: use the entire disk with the defaults. No disk encryption for the lab; the phase 1 appliance
  image adds it with TPM unlock so the hub still boots unattended.
- Profile: your name, server name `pos-hub1`, a username such as `mike`, a password.
- SSH: install the OpenSSH server, and import your SSH key from GitHub (`uwleahcim`) when offered.
- Skip the featured snaps. Reboot, remove the stick, and log in over SSH from your laptop:
  `ssh mike@pos-hub1.local` (or the address the router shows).

Debian 12 or newer works too; the script accepts Ubuntu 22.04 or newer and Debian 12 or newer. Docker comes
from Docker's own repository when it carries the release, otherwise from the distribution's packages.

## 2. Get the repository onto the hub

The repository is private, so the hub needs its own read-only key. On the hub:

```
sudo apt update && sudo apt install -y git openssh-server
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519 -C pos-hub1
cat ~/.ssh/id_ed25519.pub
```

Add that public key in GitHub under the repository's Settings, Deploy keys, Add deploy key (read-only).
Then:

```
git clone git@github.com:uwleahcim/pos.git ~/pos
```

Answer yes to GitHub's host key on the first connection.

## 3. Run the bootstrap

```
cd ~/pos
sudo ./infra/hub/bootstrap.sh --name pos-hub1
```

What it does, in order, each step only if missing:

1. Sets the hostname.
2. Installs the base packages, and Docker from Docker's own repository.
3. Makes the hub the clock for the POS network: chrony serves time to the LAN, and keeps serving it from
   its own clock when the internet is down. Every terminal and printer syncs to the hub, which keeps the
   order log's timestamps honest.
4. Turns on unattended security updates, with a reboot (only when one is needed) at 04:30.
5. Sets the firewall: SSH, the API, time and discovery from the POS network only; nothing else inbound.
6. Publishes the hub's name on the network (`pos-hub1.local`).
7. Creates `/opt/pos` with a generated database password in `.env`, builds the backend image from the
   clone, starts PostgreSQL 16 and the API with Docker Compose, and waits for the API's health check.
8. Installs `hubctl`.

| Flag | Default | Use it when |
| --- | --- | --- |
| `--name` | `pos-hub1` | The second hub: `--name pos-hub2` |
| `--lan` | detected from the default route | The hub has several networks, or detection picks the wrong one |
| `--ssh-from` | the LAN | You manage the hub from another subnet or a VPN. Without it you lock yourself out of SSH (the console still works) |
| `--admin` | the user running sudo | Another user should be in the docker group |
| `--src` | the clone the script runs from | The clone lives somewhere else |
| `--reboot-at` | `04:30` | A different quiet hour |

## 4. Check it

On the hub, `hubctl status` shows the services, the API health, the time source, the disk and the CPU
temperature. From a laptop on the same network:

```
curl http://pos-hub1.local:8000/health
```

answers `{"status":"ok","cursor":0}`. Windows laptops need Bonjour (comes with iTunes) for `.local`
names; the address works everywhere. Run the backend's own test suite against the hub's clone with
`hubctl logs api` open in another window if anything looks off.

## Where things live

| What | Where |
| --- | --- |
| Secrets (database password, node name) and `POS_PRINTERS` | `/opt/pos/.env`, readable by root only |
| `POS_LOCATION` (the restaurant's name in texts to customers) and `POS_MESSAGING` (`log` until a provider is wired in; see `docs/counter-mode.md`) | `/opt/pos/.env`, optional |
| `POS_TIMEZONE` (the restaurant's time zone, `America/New_York` unless set: menu hours, the day order numbers count through, "today" for a caller's order, the times on tickets and in texts) | `/opt/pos/.env`, optional |
| The link to the PBX for desk phones (`POS_PBX_SSH`, `POS_AMI_HOST`, `POS_AMI_USER`, `POS_AMI_SECRET`, `COMPOSE_PROFILES=pbx`; see `docs/desk-phones.md`), written by `hubctl pbx link` | `/opt/pos/.env`, optional |
| The hub's SSH key for the PBX and the PBX's host key | `/opt/pos/pbx/`, made by `hubctl pbx key` |
| The code the hub runs | `/opt/pos/src`, a link to the clone |
| PostgreSQL data | Docker volume `pos_pos-db` |
| Backups from `hubctl backup` | `/var/backups/pos/` |
| Compose file | `infra/hub/docker-compose.yml` in the clone |

## Day to day

| Command | Does |
| --- | --- |
| `hubctl status` | Services, API health, time, disk, temperature |
| `hubctl logs api` | Follow the API log (`db` for PostgreSQL) |
| `hubctl update` | Pull the clone, rebuild the image, restart what changed (the first build with face sign-in downloads its two models, about 290 MB, once; see `docs/face-signin.md`) |
| `hubctl restart` | Restart the services |
| `hubctl backup` | A compressed SQL dump of the database |
| `hubctl psql` | A database shell |
| `hubctl printers kitchen=172.19.1.162/escpos,bar=172.19.1.14/star` | Set the printers a fired order prints to (writes `POS_PRINTERS` to `.env`, restarts the API) |
| `hubctl menu import` | List what the bundled menu files would change in the hub's menu after an update: what they would add (a shelf of bottles, say), which categories they would move to another menu (the drinks to their own, `docs/menus.md`) which dishes would take the Chinese names, kitchen labels and stations the original POS had (`docs/original-pos.md`) and which prices they would move (only prices still at the online export's); `--apply` does it and keeps every change made in the menu editor |
| `hubctl print 172.19.1.162 demo` | Send the demo kitchen ticket to an Ethernet printer (`drawer` kicks the drawer; add `star` for a Star printer in StarPRNT mode) |
| `hubctl pbx key` | This hub's public key for the PBX (made on first use) and the command that adds it to the PBX's `authorized_keys` by hand |
| `hubctl pbx link root@freepbx.chinasky.org` | Link the hub to the PBX for desk phones: puts the hub's key on the PBX (its root password once), asks for the AMI secret, starts the SSH tunnel and the watcher and waits until the hub reaches the PBX (`docs/desk-phones.md`) |
| `hubctl pbx status` / `hubctl pbx tail` | How the tunnel and the watcher stand / each call as a desk phone answers it, live |
| `hubctl pbx unlink` | Stop the tunnel and forget the link |

## Ports

| Port | Who may reach it | What |
| --- | --- | --- |
| 22/tcp | `--ssh-from` (the LAN) | SSH |
| 8000/tcp | the LAN | The POS API |
| 123/udp | the LAN | Time |
| 5353/udp | the LAN | Name discovery (`pos-hub1.local`) |
| 5432/tcp | the hub itself | PostgreSQL; the standby hub gets its own rule in the failover spike |

The link to the PBX opens nothing inbound: it is an SSH connection from the hub out to the PBX (`hubctl pbx link`).

## Phase 0 only

- The order log lives in the hub's PostgreSQL (`ops` table, created on first start), so `hubctl update`
  and reboots keep every order. `hubctl backup` dumps it; replication to the second hub is the failover spike.
- Docker publishes its ports past ufw, so the API port is open to whatever can reach the hub. The hub sits
  on the closed POS network; the phase 1 appliance image adds firewall rules Docker respects.
- No disk encryption, no UPS agent and no monitoring agent yet; they come with the appliance image.
- Updates are `hubctl update`; the staged release process (test location first, standby before primary)
  arrives with the cloud in phase 2.

## The second hub

Same steps with `--name pos-hub2`. The failover spike then sets up streaming replication between the two
and the witness vote. Nothing in this guide depends on it.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| The hostname came out as `Ubuntu` | A bug in the first version of the script | `git -C ~/pos pull` and run the bootstrap again |
| `hubctl` says permission denied | An old copy of hubctl ran without root | `git -C ~/pos pull` and run the bootstrap again; hubctl now uses sudo itself |
| Locked out of SSH after the script | Your laptop is not on the LAN the script detected | Log in on the hub's console and run the script again with `--ssh-from` |
| `docker compose build` fails downloading packages | No internet on the hub, or a proxy | Check `curl -I https://pypi.org` on the hub; run the script again once it works |
| The API never becomes healthy | The container crashed | `hubctl logs api`; send the last lines to the thread |
| `pos-hub1.local` does not resolve | The laptop lacks mDNS (Windows without Bonjour) | Use the address from `hubctl status` |
| Time is not syncing | The hub has no internet and no other time source | Expected offline: the hub keeps its own clock and still serves the network; it corrects itself when the line is back |

The second hub, replication and takeover: see `FAILOVER.md`.
