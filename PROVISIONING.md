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
2. Installs **Node.js 22 LTS** and **PM2** (the process manager).
3. Sets up passwordless helpers so the app can request a service restart or reboot safely.
4. Clones this provisioning repo to `/home/bridgebox/bridge-box`.
5. Clones the scoring app and does the first `npm install` + `npm run build` into an atomic
   release folder, then points the `current` symlink at it.
6. Installs and enables the systemd services and timers (see the reference at the end).
7. Fixes ownership so everything belongs to `bridgebox`.

**Expected output:** it ends with `=== Installation complete ===` and asks you to reboot.

> **If it stops early:** open `~/install.log` and look near the bottom for the first error. The
> most common causes are no internet (Step 2) or not running as the `bridgebox` user (Step 1).
> The installer is safe to re-run once the cause is fixed.

---

## Step 4 — Reboot

```bash
sudo reboot
```

On reboot the device runs its startup automatically:
- `bridge-box-root` (as root) brings up the hotspot, firewall/NAT, and sets the hostname to
  `bridge`.
- `bridge-box-update` (as `bridgebox`) starts the app immediately, then looks for optional WiFi
  config to fetch updates, and finally returns to hotspot mode.

Give it a minute or two after boot to settle.

---

## Step 5 — Verify the hotspot and app

From a phone or laptop:

1. Look for a WiFi network named **`BridgeBox-XXXX`** and connect to it.
   - Default password: **`bridgebox`**
2. Open a browser and go to **`http://bridge.local`** (or just `http://` any address — ports 80
   and 443 are redirected to the app). The scoring app should load.

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
> **Hotspot is up but the page won't load?** Check the app log:
> ```bash
> sudo journalctl -u bridge-box-update -b
> pm2 status
> pm2 logs bridge
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
- The box connects, checks for a newer app version, updates atomically (with automatic rollback if
  the new version fails to build or start), then returns to hotspot mode.

To trigger an update cycle without rebooting:

```bash
sudo systemctl restart bridge-box-update
```

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

## Quick reference

**Network / access**
- Hotspot SSID: `BridgeBox-XXXX` (unique per device), password `bridgebox`
- App URL for guests: `http://bridge.local` (ports 80/443 → app on 3000)
- Hostname: `bridge`

**Key locations on the device**
- Provisioning scripts: `/home/bridgebox/bridge-box`
- App releases: `/home/bridgebox/bridge-box-scorer/releases/`, active via `current` symlink
- Score data (SQLite): `/home/bridgebox/data`
- Backups: `/home/bridgebox/backups` (or a mounted USB stick)
- Optional WiFi config: `/home/bridgebox/wifi.json`
- Logs: `~/install.log`, `~/root.log`, `~/update.log`, `~/healthcheck.log`, `~/backup.log`
  (all auto-truncated so they can't fill the disk)

**Services and timers**
| Unit | Runs as | Purpose |
|---|---|---|
| `bridge-box-root.service` | root | Hotspot, firewall/NAT, hostname (at boot) |
| `bridge-box-update.service` | bridgebox | Start app, optional WiFi/update, return to hotspot |
| `bridge-box-healthcheck.timer` | bridgebox | Every ~2 min: reload app if it's not responding |
| `bridge-box-backup.timer` | bridgebox | Hourly: safe SQLite backups of all databases |

**Handy commands**
```bash
pm2 status                              # is the app running?
pm2 logs bridge                         # app logs
curl -f http://localhost:3000/healthz   # health + running version
sudo systemctl restart bridge-box-update   # re-run app start + update cycle
sudo journalctl -u bridge-box-root -b       # boot-time network setup log
```

**Common issues**
- *No hotspot after boot:* check `journalctl -u bridge-box-root -b`; ensure the Pi's OS uses
  NetworkManager and `wlan0` exists.
- *Page won't load but hotspot works:* check `pm2 logs bridge` and `curl .../healthz` on the Pi.
- *Update never happens:* verify `wifi.json` is valid JSON with a reachable network; the box only
  updates when it actually gets internet.
