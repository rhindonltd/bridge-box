# Provisioning a new BridgeBox Raspberry Pi

This is a step-by-step guide to turn a fresh Raspberry Pi into a working BridgeBox — the
self-contained appliance that runs the bridge scoring app and serves it over its own WiFi hotspot.

You do not need to be a developer to follow this. Where a step needs judgement or can go wrong,
there's a note explaining what to expect.

---

## What you're building

When you're done, the Pi will:
- Boot and create its own WiFi network called **`BridgeBox-XXXX`** (the `XXXX` is unique per device).
- Serve the scoring app to anyone who joins that network — they just open a browser.
- Work with **no internet**. Internet is only used, when available, to install app updates.
- Recover on its own: it restarts the app if it crashes or hangs, and takes hourly backups of the
  score data.

---

## Before you start — what you need

- A **Raspberry Pi** (Pi 4 or newer recommended) with a power supply.
- An **SSD** (the device is designed to run from an SSD, not an SD card) with a fresh install of
  **Raspberry Pi OS (64-bit, "Bookworm" or newer)**. Raspberry Pi OS uses NetworkManager by
  default, which this setup relies on.
- A way to reach the Pi to run commands: either a keyboard + monitor, or SSH from another computer.
- The Pi connected to the internet **for the install only** (Ethernet cable is easiest and most
  reliable; WiFi also works). After install it runs offline.
- About 15–20 minutes, most of which is unattended downloading/building.

> The Pi's built-in WiFi (`wlan0`) becomes the guest hotspot, so for the install itself prefer a
> wired Ethernet connection. If you must use WiFi for the install, that's fine — the install
> finishes by switching `wlan0` into hotspot mode.

---

## Step 1 — Create the `bridgebox` user

The whole system expects a user named exactly **`bridgebox`** with a home directory at
`/home/bridgebox`. The installer will refuse to run as anyone else.

If your OS image already has a `bridgebox` user, log in as that user and skip to Step 2.

Otherwise, from any admin account on the Pi:

```bash
sudo adduser bridgebox
sudo usermod -aG sudo bridgebox
```

Then log in as `bridgebox` (or `su - bridgebox`) for the rest of the guide.

> The user must be able to run `sudo`. The installer configures a few passwordless sudo helpers,
> but the install itself will prompt for the `bridgebox` password when it needs elevated rights.

---

## Step 2 — Confirm internet access

The install needs to download system packages, Node.js, and the app.

```bash
ping -c 3 8.8.8.8
```

If you see replies, you're good. If not, connect Ethernet (or join WiFi) and try again before
continuing.

---

## Step 3 — Run the installer

Run this as the `bridgebox` user. It downloads the installer and logs everything to
`~/install.log` so you can review it if anything goes wrong.

```bash
curl -sSL https://raw.githubusercontent.com/rhindonltd/bridge-box/refs/heads/main/install.sh | bash -x 2>&1 | tee ~/install.log
```

**What this does, in order (roughly 10–15 min):**
1. Installs system dependencies: `git`, `curl`, `avahi-daemon`, `iptables` (+ persistence), `jq`,
   `sqlite3`.
2. Installs **Node.js** (current LTS, from the NodeSource repo). The app runs as a native systemd
   service (no separate process manager).
3. Sets up passwordless helpers so the app can request a service restart or reboot safely.
4. Clones this provisioning repo to `/home/bridgebox/bridge-box`.
5. Clones the scoring app and does the first `npm install` + `npm run build` into an atomic
   release folder, then points the `current` symlink at it.
6. Installs and enables the systemd services and timers (see the reference at the end).
7. Fixes ownership so everything belongs to `bridgebox`.

**Expected output:** it ends with `=== Installation complete ===` and asks you to reboot.

> **If it stops early or the Pi loses power mid-install:** the install is designed to be **re-run
> from the top** — it cleans up and rebuilds as it goes. See
> [Recovering from an interrupted install](#recovering-from-an-interrupted-install) below before
> you reboot. As a rule: **only reboot (Step 4) once you've seen `=== Installation complete ===`.**

---

## Step 4 — Reboot

```bash
sudo reboot
```

On reboot the device runs its startup automatically:
- `bridge-box-root` (as root) brings up the hotspot, firewall/NAT, and sets the hostname to
  `bridge`.
- `bridge-box-online-tasks` (as `bridgebox`) does all the network chores in **one** short online
  window (only if `wifi.json` is present): it activates any update that was built last session, then
  briefly switches to your WiFi to **download** any newer app version and **refresh the EBU player
  list**, then switches back to the hotspot. It does **not** run the app.
- `bridge-box-app` runs the scoring app itself, supervised by the system — it starts at boot and is
  automatically restarted if it ever stops.
- `bridge-box-build` (as `bridgebox`) quietly builds a freshly-downloaded version in the background;
  that version goes live the **next** time the box is switched on.

How updates work (worth knowing):
- The box only does network chores (update download, player-list refresh) **at switch-on**, in one
  window **before anyone is using it** — never on a timer that could interrupt a session. This suits
  a device that's unplugged and put away between sessions.
- That window **downloads the new version and fetches its dependencies** while online (needs a
  working `wifi.json`, can take a few minutes); the slower **compile** happens in the background
  afterwards, and the new version goes live at the *next* switch-on. So a release lands one session
  after it's published. An offline box (no `wifi.json`) skips all this.
- The app runs as its own service, independent of all this — it keeps serving on the current version
  throughout, and the brief network switch happens at boot before anyone connects (never
  mid-session). You can also trigger the chores manually when idle: `bridge update-now`,
  `bridge sync-players`.

Give it a minute or two after boot to settle.

---

## Step 5 — Verify the hotspot and app

From a phone or laptop:

1. Look for a WiFi network named **`BridgeBox-XXXX`** and connect to it.
   - Default password: **`bridgebox`**. This is meant to be a known, posted password — print it
     (with the network name) on a card for the table so players can join quickly.
   - To use a different password, create `/home/bridgebox/hotspot.conf` with
     `HOTSPOT_PASS="your-password"` and reboot (or restart `bridge-box-root`). You can always read
     the box's current SSID + password with `cat /home/bridgebox/hotspot-credentials.txt`.
2. Open a browser and go to **any** web address — the box redirects everything to itself, so the
   scoring app should load whatever you type (you don't need to know `bridge.local`). On many
   phones a "sign in to network" page pops up on its own after joining, showing the app directly.
   There is **no login** — players go straight to the main menu and start scoring.

On the Pi itself you can confirm the app is healthy:

```bash
curl -f http://localhost:3000/healthz
```

A `200` response with JSON means the app is up and its databases are reachable. The JSON also
shows the running version/commit.

> **Don't see the hotspot?** Check the network setup log:
> ```bash
> sudo journalctl -u bridge-box-root -b
> ```
> **Hotspot is up but the page won't load?** Check the app service:
> ```bash
> bridge status
> bridge logs
> systemctl status bridge-box-app
> ```

---

## Step 6 (optional) — Connect the box to real WiFi for updates

By default the box runs purely offline. If you want it to pull app updates when internet is
available, give it WiFi credentials by creating **`/home/bridgebox/wifi.json`**:

```bash
cat > /home/bridgebox/wifi.json <<'EOF'
{
  "ssid": "YourNetworkName",
  "password": "YourNetworkPassword",
  "hidden": "no"
}
EOF
```

- Set `"hidden": "yes"` only if your network doesn't broadcast its name.
- On each switch-on the box connects, downloads any newer app version, and returns to the hotspot;
  it builds that version in the background and activates it on the following switch-on (with
  automatic rollback if the new version turns out not to start). So updates land one session later.
- The file holds your WiFi password in plaintext; the box tightens it to `chmod 600` automatically.

**Pinning the app version (optional).** By default the box tracks the `main` branch. To pin a
device (or a fleet) to a specific released version for reproducibility, create
`/home/bridgebox/release.conf`:

```bash
echo 'RELEASE_REF="v1.4.0"' > /home/bridgebox/release.conf
```

`RELEASE_REF` can be a branch or a tag. The box deploys the exact commit that ref points to.

To force an update check now (downloads a newer version; it still builds in the background and goes
live at the next switch-on) — this briefly drops the hotspot, so run it when no one is playing:

```bash
bridge update-now
```

The simplest way to fully apply an update is just to switch the box off and on twice: once to
download + build, and the next time to run the new version.

> If `wifi.json` is missing or invalid, or the network can't be reached, the box just stays in
> hotspot mode and keeps serving — this is by design.

---

## Step 7 — Final checks

Confirm the automatic maintenance is scheduled:

```bash
systemctl list-timers | grep bridge-box
```

You should see both **`bridge-box-healthcheck.timer`** (every ~2 min) and
**`bridge-box-backup.timer`** (hourly).

Confirm a backup has run (after the first hour, or trigger one now):

```bash
sudo systemctl start bridge-box-backup
ls -la /home/bridgebox/backups            # on-disk backups
```

If you plug in a USB stick (mounted under `/media/bridgebox/...`), backups go there instead,
under a `bridge-box-backups` folder.

The box is now ready for use. Power it off/on as needed — it comes back up on its own.

---

## Ongoing maintenance

**OS security updates (manual, occasional).** The box does **not** update its operating system
automatically — this keeps it predictable and avoids a surprise kernel/firmware change breaking it
mid-session. Every so often, when no game is running, apply OS updates by hand:

```bash
sudo /home/bridgebox/bridge-box/bridge-box-os-update.sh
sudo reboot   # if it says the kernel changed
```

You don't need to connect the box to the internet first: if it isn't already online, the script
temporarily switches to the WiFi network in `wifi.json`, does the update, and switches back to the
hotspot automatically. (It needs a valid `wifi.json` — see Step 6 — or an Ethernet cable.)

**Node.js version.** Node is installed from the NodeSource repository, pinned to a major version
(24 by default). Routine OS updates keep it patched *within* that major but never jump to a new one
(e.g. they won't move you from 24 to 25). When you do want to move to a newer major — after the app
has been confirmed to support it — do it deliberately:

```bash
sudo /home/bridgebox/bridge-box/bridge-box-node-upgrade.sh 26   # example target major
curl -f http://localhost:3000/healthz                           # confirm the app still runs
```

The script re-points the package source and rebuilds the current app release against the new Node
so nothing is left compiled against the old version. Like the OS-update script, it will switch to
the `wifi.json` network for internet if needed and return to the hotspot afterwards. Don't do this
mid-session.

**Captive portal (auto-appearing app).** By default the box redirects all guest DNS to itself, so
opening any web address shows the app and most phones pop it up automatically on join. This does
not affect the box's own internet access for updates. To turn it off (guests would then need to
type `bridge.local` themselves):

```bash
echo 'CAPTIVE_PORTAL="no"' > /home/bridgebox/captive.conf
sudo systemctl restart bridge-box-root   # or reboot
```

**Player list (EBU).** The box keeps a local copy of the EBU player list (so directors can search
players offline). It's populated during provisioning and refreshed automatically about once a day
**when the box has internet** (it briefly switches to the `wifi.json` network, syncs, and switches
back). If a box was provisioned offline, player search returns nothing until the first successful
sync. Force one now with `bridge sync-players` (needs internet). Details in
`/home/bridgebox/player-sync.log`.

**App logs.** The scoring app's own logs go to the system journal (`bridge logs`, or
`journalctl -u bridge-box-app`). To collect them for analysis, `bridge ship-logs` exports everything
since the last export to a timestamped file under `/home/bridgebox/log-ship/exports/` (it tracks a
cursor, so each run only adds what's new). This is a **local** export for now — nothing leaves the
box. (Sending them to an external service later is a small change; it would then run in the boot
online window rather than mid-session, and you'd want to consider that logs may contain player data.)

**Backups.** Score data is backed up hourly and automatically. Backups are stored **on the device**
(or on a USB stick if one is plugged in) — they are not sent anywhere off the box. If you want an
off-site copy, periodically copy the newest files out of `/home/bridgebox/backups` (or the USB
stick) to somewhere safe. Note these files contain player/game data, so treat them accordingly.

---

## Recovering from an interrupted install

If the install stops early — an error, a dropped connection, or the Pi losing power partway
through — the box may be **half provisioned**. This is safe to recover from: no score data exists
yet, so the worst case is a box that doesn't work until you finish the install.

**How to tell if provisioning finished.** The installer writes a marker file only on full success:

```bash
ls -l /home/bridgebox/.provisioned
```

- **File exists** → provisioning completed. A reboot is safe.
- **File missing** → provisioning did **not** finish. Do **not** rely on a reboot — **re-run the
  installer** (Step 3) instead. It is designed to be run again: it re-clones and rebuilds cleanly,
  and it refuses to enable the app services unless the app actually built.

**Special case — interrupted while installing system packages.** If the interruption happened
during the `apt` package step, the package manager can be left half-configured, and re-running the
installer will fail at the install step. Fix the package state first, then re-run the installer:

```bash
sudo dpkg --configure -a
sudo apt-get -f install
```

**General recovery procedure:**
1. Make sure the Pi has internet again (`ping -c 3 8.8.8.8`).
2. If the interruption was during package install, run the two `dpkg`/`apt` commands above.
3. Re-run the installer (Step 3).
4. Wait for `=== Installation complete ===` and confirm `/home/bridgebox/.provisioned` exists.
5. Only then reboot (Step 4).

> Why this is safe: the installer clears the marker at the start and only rewrites it at the very
> end, re-clones the repos and rebuilds the app each run, and will **abort rather than enable a
> half-built app** — so a reboot can never bring up a crash-looping, broken box.

---

## Quick reference

**Network / access**
- Hotspot SSID: `BridgeBox-XXXX` (unique per device); password defaults to `bridgebox`, overridable
  via `hotspot.conf` — current value in `/home/bridgebox/hotspot-credentials.txt`
- App URL for guests: `http://bridge.local` (ports 80/443 → app on 3000)
- Hostname: `bridge`

**Key locations on the device**
- Provisioning scripts: `/home/bridgebox/bridge-box`
- App releases: `/home/bridgebox/bridge-box-scorer/releases/`, active via `current` symlink
- Score data (SQLite): `/home/bridgebox/data` (per-game DBs under `/home/bridgebox/data/games`)
- Backups: `/home/bridgebox/backups` (or a mounted USB stick)
- Optional WiFi config: `/home/bridgebox/wifi.json` (auto `chmod 600`)
- Hotspot credentials (generated): `/home/bridgebox/hotspot-credentials.txt`
- Optional hotspot password override: `/home/bridgebox/hotspot.conf` (`HOTSPOT_PASS="..."`)
- Optional version pin: `/home/bridgebox/release.conf` (`RELEASE_REF="..."`)
- Optional captive-portal toggle: `/home/bridgebox/captive.conf` (`CAPTIVE_PORTAL="no"`)
- Optional app env override: `/home/bridgebox/scorer.env` (else the built-in template with absolute
  `DATABASE_URL=/home/bridgebox/data` and `DATABASE_GAMES_URL=/home/bridgebox/data/games` is used)
- Provisioning-complete marker: `/home/bridgebox/.provisioned` (present only after a successful install)
- Logs: `~/install.log`, `~/root.log`, `~/update.log`, `~/healthcheck.log`, `~/backup.log`
  (all auto-truncated so they can't fill the disk)

**Services and timers**
| Unit | Runs as | Purpose |
|---|---|---|
| `bridge-box-root.service` | root | Hotspot, firewall/NAT, hostname (at boot) |
| `bridge-box-app.service` | bridgebox | Runs the scoring app (auto-restarts if it stops) |
| `bridge-box-online-tasks.service` | bridgebox | Boot: one online window — activate pending update, download a new one, refresh player list |
| `bridge-box-build.service` | bridgebox | Boot (background, low priority): build a downloaded update |
| `bridge-box-player-sync.service` | bridgebox | Manual only (`bridge sync-players`) — no timer; runs in an online window |
| `bridge-box-healthcheck.timer` | bridgebox | Every ~2 min: restart the app if it's not responding |
| `bridge-box-backup.timer` | bridgebox | Hourly: safe SQLite backups of all databases |

**Handy commands**
A single `bridge` command wraps the common tasks — run `bridge help` for the full list. The main
ones:

```bash
bridge status        # is the app running? (service status + health check)
bridge logs          # follow the app logs (Ctrl-C to stop)
bridge restart       # restart the app
bridge update-now    # check for an app update now (goes live next switch-on)
bridge os-update     # apply OS security updates (switches to WiFi, then back)
bridge node-upgrade 24   # move Node.js to a new major version
bridge backup-now    # take a data backup now
bridge sync-players  # update the EBU player list now (needs internet)
bridge ship-logs     # export app logs since last run (local file for now)
bridge version       # show the running app version
bridge wifi          # show WiFi config (or: bridge wifi <ssid> <password> [hidden])
bridge password      # show this box's hotspot SSID + password
bridge reboot        # reboot the box
```

These are thin wrappers over the underlying scripts/services — you can still call those directly if
you prefer (e.g. `sudo /home/bridgebox/bridge-box/bridge-box-os-update.sh`, `journalctl -u
bridge-box-online-tasks -b`).

**Common issues**
- *No hotspot after boot:* check `journalctl -u bridge-box-root -b`; ensure the Pi's OS uses
  NetworkManager and `wlan0` exists.
- *Page won't load but hotspot works:* check `bridge logs` (or `systemctl status bridge-box-app`) and `curl .../healthz` on the Pi.
- *Update never happens:* verify `wifi.json` is valid JSON with a reachable network; the box only
  updates when it actually gets internet.
- *App doesn't appear automatically (have to type `bridge.local`):* the captive portal may have
  failed to configure. Check `sudo journalctl -u bridge-box-root -b` for a captive-portal warning,
  and confirm the drop-in exists: `ls /etc/NetworkManager/dnsmasq-shared.d/`. Typing `bridge.local`
  always works as a fallback.
