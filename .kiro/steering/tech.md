# Tech Stack

## Platform
- **Target hardware**: Raspberry Pi running Debian/Raspberry Pi OS (`apt`, `systemd`, `nmcli`/NetworkManager).
- **Runtime**: Node.js LTS from the NodeSource apt repo, pinned to a major line via `NODE_MAJOR` in `install.sh` (default 24). `apt upgrade` stays within the major; major upgrades are a manual step (`bridge-box-node-upgrade.sh`).
- **Process supervision**: native **systemd** service `bridge-box-app.service` (`Restart=always`) — no PM2.
- **App server**: The scorer app (separate `bridge-box-scorer` repo) is a Next.js + Socket.IO app; production entrypoint is `node dist/server.js` (falls back to `tsx server.ts`), listening on port `3000`.

## Languages
- **Bash** — all provisioning, networking, and update logic lives in shell scripts.
- **JavaScript** — the app is external (`bridge-box-scorer`); this repo is shell + systemd units.
- **JSON** — config (`wifi.json`, etc.).

## System tooling relied on
- `nmcli` (NetworkManager) for the WiFi hotspot and client connections.
- `iptables` / `iptables-persistent` / `netfilter-persistent` for NAT and port redirects.
- `avahi-daemon` for mDNS (`bridge.local`).
- `jq` for parsing `wifi.json`.
- `git` for cloning/updating releases; `sqlite3` available for app data.

## Conventions
- All scripts start with `set -euo pipefail` — keep this; fail fast.
- Scripts log to a dedicated file via `exec > >(tee -a "$LOGFILE") 2>&1` and to the systemd journal.
- Paths and tunables (interface, ports, dirs, repo URLs) are defined as variables at the top of each script — add new config there, not inline.
- Destructive `rm -rf` must be guarded with a path check before deleting (see the release-cleanup guard in `bridge-box-update.sh`).

## Common commands

Install / provision a fresh Pi (run as the `bridgebox` user):
```bash
curl -sSL https://raw.githubusercontent.com/rhindonltd/bridge-box/refs/heads/main/install.sh | bash -x 2>&1 | tee ~/install.log
```

Service management (on the device):
```bash
sudo systemctl status bridge-box-root bridge-box-update
sudo systemctl restart bridge-box-update   # re-run app start + update flow
sudo journalctl -u bridge-box-root -f       # follow root/network setup logs
sudo journalctl -u bridge-box-update -f     # follow app/update logs
```

App service:
```bash
bridge status                 # or: systemctl status bridge-box-app
bridge logs                   # or: journalctl -u bridge-box-app -f
bridge restart                # or: sudo systemctl restart bridge-box-app
```

Logs on device: `/home/bridgebox/{root,update,build,healthcheck,backup}.log`; app logs via `journalctl -u bridge-box-app`.
