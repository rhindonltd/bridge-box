# Project Structure

This repo is small and flat — it is the provisioning layer, cloned onto the device at `/home/bridgebox/bridge-box`.

## Files

- `install.sh` — One-time factory installer. Run as the `bridgebox` user on a fresh Pi. Installs system deps + Node 22 + PM2, configures passwordless sudo helpers, clones this repo and the scorer app, sets up the atomic release layout, and installs/enables the two systemd services.
- `bridge-box-root.service` / `bridge-box-root.sh` — Runs as **root** at boot (before the update service). Brings up the WiFi hotspot, enables IP forwarding, sets up iptables NAT (80/443 → 3000), and sets the hostname to `bridge`.
- `bridge-box-update.service` / `bridge-box-update.sh` — Runs as the **bridgebox** user after root setup. Starts the app via PM2 immediately, waits (bounded) for `wifi.json`, connects to real WiFi if available, performs atomic app updates with rollback, then returns to hotspot mode. A `trap ... EXIT` guarantees the box returns to hotspot mode on any exit path; network/build steps are wrapped in `timeout`.
- `bridge-box-healthcheck.service` / `.timer` / `bridge-box-healthcheck.sh` — Periodic watchdog (every ~2 min) that curls the app on `:3000` (health endpoint if available, else root URL) and `pm2 reload`s it if unresponsive. Catches the "hung but alive" case PM2 alone misses.
- `bridge-box-backup.service` / `.timer` / `bridge-box-backup.sh` — Hourly SQLite online backup (`sqlite3 .backup`) of **all** databases found recursively under `data/` (the app uses multiple: game-index, per-game, player, settings), preferring a mounted USB stick under `/media/bridgebox`, else `backups/`. Backup filenames encode the relative path so per-game DBs in subdirs don't collide; retains the newest N per database.
- `main-app.js` — Minimal ESM launcher that runs `npm start` for the scorer app. Referenced by `pm2.json`.
- `scorer-app-improvements.md` — Notes on robustness improvements that belong in the separate `bridge-box-scorer` repo (SQLite WAL, `/healthz`, lockfile, graceful shutdown, etc.).
- `pm2.json` — PM2 ecosystem config (`bridge-app`, production env, `DATABASE_URL=/home/bridgebox/data`).
- `README.md` — Install one-liner.

## Runtime layout on the device (created by install/update)

```
/home/bridgebox/
├── bridge-box/                     # this repo
├── bridge-box-scorer/
│   ├── releases/<commit-or-name>/  # each deployed app version
│   ├── current   -> releases/...   # active release (symlink)
│   └── previous  -> releases/...   # last-good release for rollback (symlink)
├── data/                           # app data (DATABASE_URL), SQLite DBs
├── backups/                        # on-disk backups (fallback when no USB)
├── wifi.json                       # user-supplied WiFi config { ssid, password, hidden }
├── root.log                        # bounded (auto-truncated ~5 MB)
├── update.log                      # bounded (auto-truncated ~5 MB)
├── healthcheck.log                 # bounded (auto-truncated ~2 MB)
└── backup.log                      # bounded (auto-truncated ~2 MB)
```

USB backups (when a stick is mounted): `/media/bridgebox/<mount>/bridge-box-backups/`.

Also installed system-wide:
- `/etc/systemd/system/bridge-box-{root,update}.service`
- `/etc/systemd/system/bridge-box-{healthcheck,backup}.service` and `.timer`
- `/usr/local/bridgebox/bin/{restart-service,reboot}.sh` (root-owned, invoked via sudoers)
- `/etc/sudoers.d/bridgebox`

## Rules for changes
- The two systemd services have an ordering contract: `root` sets up network/firewall first, then `update` runs the app. Preserve `After=`/`Requires=`/`Before=` when editing.
- Keep the boot-time app start independent of internet — never make app startup depend on a successful WiFi/update step.
- Preserve the atomic release + symlink + rollback pattern for any deployment changes.
- `bridge-box-update.sh` must always end back in hotspot mode — keep the `trap ... EXIT` restore and prefer `exit 0` (stay serving) over `exit 1` for recoverable network/update failures.
- Wrap any network, clone, install, or build step in a `timeout` so a hang can't wedge the boot flow.
- Keep logs bounded (the truncate-on-start guard) so they can't fill the disk over the life of the device.
- The app reads `APP_COMMIT` to display the running version (via `/healthz` and a UI footer). `bridge-box-update.sh` resolves the current release's commit and passes `APP_COMMIT` to PM2 at start, reload, and rollback (`pm2 reload --update-env`). Keep this wired when changing the deploy flow.
- The actual scoring UI/logic belongs in the separate `bridge-box-scorer` repo, not here. That repo documents its own durability/operations notes (`durability-and-operations.md`).
