# Project Structure

This repo is small and flat — it is the provisioning layer, cloned onto the device at `/home/bridgebox/bridge-box`.

## Files

- `install.sh` — One-time factory installer. Run as the `bridgebox` user on a fresh Pi. Installs system deps + Node.js (NodeSource, `NODE_MAJOR` default 24) + PM2, configures passwordless sudo helpers, clones this repo and the scorer app, sets up the atomic release layout, and installs/enables the systemd services and timers.
- `bridge-box-root.service` / `bridge-box-root.sh` — Runs as **root** at boot (before the update service). Brings up the WiFi hotspot (per-device password), enables IP forwarding, applies NAT via `bridge-box-nat.sh`, and sets the hostname to `bridge`.
- `bridge-box-update.service` / `bridge-box-update.sh` — Runs as the **bridgebox** user after root setup. Single-instanced via `flock`. Implements **Phase 3** (activate a built `pending` release) and **Phase 1** (download-only, bounded) of the update model below, then **always starts the app** via a `trap ... EXIT` (a network failure must never leave the box with no app). The network phase runs entirely BEFORE the app starts (no WiFi churn while serving) and is capped by a hard deadline (`PHASE1_DEADLINE`, 90s); if there is no `wifi.json` it skips the network phase instantly for a fast offline boot. It does NOT build here.
- `bridge-box-build.service` / `bridge-box-build.sh` — **Phase 2.** Runs as **bridgebox** after the update service, at low CPU/IO priority (`Nice=19`, `IOSchedulingClass=idle`). Builds a downloaded-but-unbuilt release (marked `.needs_build`) with no network activity, then marks it `.built` and points `pending` at it for activation next boot. Power-cut safe: never touches `current`; a half-built release is retried on the next boot.
- `bridge-box-nat.sh` — Idempotent NAT/port-redirect script (guest 80/443 → app `APP_PORT`). Shared by `bridge-box-root.sh` (at boot) and re-applied after an update cycle via the `apply-nat.sh` sudo helper. Run as root.
- `bridge-box-captive.sh` — Captive-portal DNS hijack. Writes a NetworkManager shared-dnsmasq drop-in (`/etc/NetworkManager/dnsmasq-shared.d/`) that resolves **all** hotspot DNS to the box's own IP, so guests who open any URL land on the app. Scoped to the hotspot only (does not affect the box's own outbound DNS during updates). Derives the hotspot IP at runtime; toggle via `captive.conf`. Run as root from `bridge-box-root.sh` before NAT.
- `bridge-box-wifi-lib.sh` — Shared, sourced library of WiFi helpers (`bb_wifi_online`, `bb_connect_wifi`, `bb_have_internet`, `bb_return_to_hotspot`, `bb_acquire_lock`). Single source of truth for switching `wlan0` to the `wifi.json` client network and returning to hotspot mode. Sourced by **all** scripts that touch the network: `bridge-box-update.sh` (boot), `bridge-box-os-update.sh`, and `bridge-box-node-upgrade.sh`.
- `bridge-box-os-update.sh` — **Manual**, admin-run OS maintenance (`apt upgrade`). Deliberately NOT run automatically; see OS-update policy below. Auto-switches to client WiFi (via the lib) if not already online, then returns to hotspot.
- `bridge-box-node-upgrade.sh` — **Manual**, admin-run Node.js **major** upgrade (e.g. 22 → 24). Re-points the NodeSource apt repo to a new major and rebuilds the current release against it. See Node policy below. Also auto-switches to client WiFi via the lib.
- `bridge-box-healthcheck.service` / `.timer` / `bridge-box-healthcheck.sh` — Periodic watchdog (every ~2 min) that curls the app on `:3000` (health endpoint if available, else root URL) and `pm2 reload`s it if unresponsive. Catches the "hung but alive" case PM2 alone misses.
- `bridge-box-backup.service` / `.timer` / `bridge-box-backup.sh` — Hourly SQLite online backup (`sqlite3 .backup`) of **all** databases found recursively under `data/` (the app uses multiple: game-index, per-game, player, settings), preferring a mounted USB stick under `/media/bridgebox`, else `backups/`. Backup filenames encode the relative path so per-game DBs in subdirs don't collide; retains the newest N per database.
- `bridge-box-deploy-env.sh` — Drops the scorer `.env` into a release dir before building (box-local `scorer.env` if present, else `scorer.env.template`) and ensures `data/`+`data/games/` exist. Called by `install.sh` and `bridge-box-build.sh` before their builds. Single source of truth for supplying build-time env.
- `scorer.env.template` — Template `.env` for the scorer app (gitignored in that repo but needed at build time). Absolute DB paths only; no `NEXT_PUBLIC_APP_URL` (the app uses same-origin for sockets).
- `main-app.js` — Minimal ESM launcher that runs `npm start` for the scorer app. Referenced by `pm2.json`.
- `pm2.json` — PM2 ecosystem config (`bridge-app`, production env: `DATABASE_URL`, `DATABASE_GAMES_URL`, `PORT`, `HOST`, `APP_COMMIT`).
- `PROVISIONING.md` — Step-by-step guide for provisioning a new Pi, including interrupted-install recovery.
- `README.md` — Install one-liner.
- (The scorer app's own durability/operations notes live in the separate `bridge-box-scorer` repo as `durability-and-operations.md`.)

## Runtime layout on the device (created by install/update)

```
/home/bridgebox/
├── bridge-box/                     # this repo
├── bridge-box-scorer/
│   ├── releases/<commit>/          # each release; may contain .needs_build or .built markers
│   ├── current   -> releases/...   # active release (symlink)
│   ├── previous  -> releases/...   # last-good release for rollback (symlink)
│   └── pending   -> releases/...   # built release awaiting activation next boot (symlink)
├── data/                           # app data (DATABASE_URL), SQLite DBs
├── backups/                        # on-disk backups (fallback when no USB)
├── wifi.json                       # user-supplied WiFi config { ssid, password, hidden } (chmod 600)
├── hotspot.conf                    # optional: HOTSPOT_PASS override (else derived from MAC)
├── hotspot-credentials.txt         # generated: effective SSID + password (chmod 600)
├── release.conf                    # optional: RELEASE_REF="<branch|tag>" to pin deploys
├── captive.conf                    # optional: CAPTIVE_PORTAL="no" to disable the portal
├── scorer.env                      # optional: box-local .env override (else the repo template is used)
├── .provisioned                    # marker: present only after a successful install
├── .update.lock                    # flock file for single-instance update runs
├── root.log                        # bounded (auto-truncated ~5 MB)
├── update.log                      # bounded (auto-truncated ~5 MB)
├── build.log                       # bounded (auto-truncated ~5 MB) — Phase 2 build
├── healthcheck.log                 # bounded (auto-truncated ~2 MB)
└── backup.log                      # bounded (auto-truncated ~2 MB)
```

USB backups (when a stick is mounted): `/media/bridgebox/<mount>/bridge-box-backups/`.

Also installed system-wide:
- `/etc/systemd/system/bridge-box-{root,update,build}.service`
- `/etc/systemd/system/bridge-box-{healthcheck,backup}.service` and `.timer`
- `/usr/local/bridgebox/bin/{restart-service,reboot,apply-nat}.sh` (root-owned, invoked via sudoers)
- `/etc/sudoers.d/bridgebox`
- `/etc/NetworkManager/dnsmasq-shared.d/010-bridgebox-captive.conf` (captive-portal DNS drop-in)

## Install / provisioning invariants
- `install.sh` is intended to be **safe to re-run** (re-clones, rebuilds, `mkdir -p`, `ln -sfn`, `enable` are idempotent).
- It clears `/home/bridgebox/.provisioned` at the start and writes it only on full success; absence of that marker means "not fully provisioned — re-run rather than trust a reboot."
- It must **not** enable the app services unless `current` points at a successfully built release (guard in step 8), so an interrupted install can't leave a reboot bringing up a crash-looping app.

## App update model (three phases)
Updates are tied to the **power cycle**, not a schedule (the box lives in a cupboard between
sessions, so timers are useless; and the director just unplugs it, so there's no end-of-session
action). The design keeps switch-on-to-game fast while still updating:
- **Phase 1 — boot, before the app starts (network):** if `wifi.json` exists, connect to the club
  WiFi (fast-fail, hard 90s deadline), compare the pinned `RELEASE_REF` to the **newest downloaded**
  release (not just `current`, so an un-activated download isn't re-fetched), `git clone`+checkout a
  newer release if any, mark it `.needs_build`, return to hotspot. **Download only — no build.** No
  `wifi.json` → skip instantly. The app is then always started (via trap).
- **Phase 2 — background, after boot (`bridge-box-build.service`, no network):** low-priority
  `npm ci`+build of the `.needs_build` release; on success mark `.built` and set `pending`; on
  failure discard. Never touches the running app.
- **Phase 3 — next boot, before the app starts:** if a `.built` `pending` release exists, atomically
  point `current` at it (old → `previous`) and clear `pending`, then start the app on the new code.

Net effect: download this session → build in background this session → activate next session. Boot
is fast (no build on the critical path), no WiFi switching while the app runs, and a plug-pull at
any point is harmless (only `pending`/marker flips are load-bearing; `current` is only ever moved
at the very start of a boot). Invariants to preserve:
- The app MUST always start, even if the whole network phase fails (keep the trap-based start).
- Never build in `bridge-box-update.sh`; never do network in `bridge-box-build.sh`.
- Only advance `current` via Phase 3 at boot start; never swap it mid-session.

## Design decisions & policies
- **The app is started by launching its entrypoint directly, not via `npm start`** (npm/tsx under systemd is fragile: PATH resolution + the `exec` in the app's start script makes PM2 lose the process). `start_app` picks, per release, in order: (1) `node dist/server.js` — the compiled build, no tsx/npm (the target); (2) `tsx server.ts` via absolute path + `--interpreter none` — interim, for releases predating the compile; (3) `npm start` — last resort. It adds `--node-args=--require ./scripts/allow-server-only.cjs` only if that shim still exists in the release. `start_app` verifies the process is `online` (not just that `pm2 start` was issued).
- **Services that launch/talk to PM2 need BOTH `HOME`/`PM2_HOME` AND `KillMode=process`.** Two separate systemd+PM2 traps:
  1. systemd doesn't set `$HOME` from `User=`, so without `Environment=HOME=/home/bridgebox` + `PM2_HOME=/home/bridgebox/.pm2` PM2 uses a different home than an interactive shell and `pm2 status` can't see the app.
  2. PM2's daemon double-forks into the background; a script that starts it and exits would, under the default `KillMode`, have the daemon (and the app) reaped by systemd when the script's cgroup is torn down — the app "starts" then immediately "Deactivated successfully" with an empty `pm2 list`. **`KillMode=process`** makes systemd kill only the main script, leaving PM2 alive.
  The `update` service is `Type=oneshot`+`RemainAfterExit=yes`+`KillMode=process`; `build` and `healthcheck` (oneshot, use PM2) also set `KillMode=process`. Keep all of this on any new PM2-using unit. `start_app` also verifies the process is `online` rather than assuming success.
  - Because it's `Type=oneshot`, the update script's **exit code is the job result**, so its `finish` trap forces `exit 0` (the script's job is "always get the app running"; app liveness is owned by PM2 + the healthcheck timer, not by this unit's status). Consequently **systemd status is NOT a reliable "is the app up" signal** — use `pm2 status` / `curl /healthz` for that. Don't "fix" the forced `exit 0` into propagating failures, or a benign diagnostic non-zero will mark the boot failed.
- **PM2 boot resurrection is intentionally NOT configured** (no `pm2 startup`). `bridge-box-update.service` is the single app start path on every boot; adding `pm2 startup` would create a competing one. Don't "fix" this.
- **No automatic OS updates.** The boot flow does not run `apt upgrade`, so the appliance is predictable and can't be broken by an unattended kernel/firmware change during a club session. Security updates are applied manually and occasionally by an admin via `bridge-box-os-update.sh` when the box has internet. This is a deliberate tradeoff (predictability over automatic patching).
- **Node.js install & upgrades.** Node is installed from the **NodeSource apt repo**, pinned to a major line via `NODE_MAJOR` in `install.sh` (default **24**, current LTS). A routine `apt upgrade` only moves *within* that major (e.g. 24.x.y); it never crosses majors. A **major** bump (e.g. 22 → 24) is a deliberate, hands-on step via `bridge-box-node-upgrade.sh`, which re-points the repo and rebuilds the current release so native modules match. Note `systemctl restart bridge-box-update` alone does NOT rebuild an unchanged release — the node-upgrade script rebuilds explicitly.
- **Hotspot password is a known, posted credential** (#8), because any player in the room must be able to join quickly. Default is `bridgebox`; a club can override it via `HOTSPOT_PASS="..."` in `hotspot.conf`. The effective SSID + password are written to `hotspot-credentials.txt` (chmod 644) so an admin can print them for the table. This is a deliberate usability-over-secrecy choice — the hotspot is local-only and NATs to the app.
- **`wifi.json` is chmod 600** (#9) — it holds the club WiFi password in plaintext.
- **`APP_COMMIT` format** is the 7-char short hash. On a box that has never updated it shows the initial release label `app_initial` until the first successful update (#11) — expected, not a bug.
- **Deploys can be pinned** (#12): `RELEASE_REF` (default `main`) in `release.conf` selects the branch/tag; the update checks out the exact resolved commit. Use a tag for reproducible fleet deployments.
- **The scorer `.env` is supplied by provisioning at build time.** It's gitignored in the app repo but the build (prebuild migration + `next build`) needs it, and each release is a fresh clone, so `bridge-box-deploy-env.sh` writes it into every release dir before building. Values use **absolute** paths (`/home/bridgebox/data`, `.../data/games`) so DBs live outside the pruned release dirs. Precedence: the app treats real env vars as authoritative and `.env` only fills gaps, so the running values come from `pm2.json` (which sets both DB vars); the `.env` mainly satisfies the build — keep the two in sync. Box-local override: `/home/bridgebox/scorer.env`. `NEXT_PUBLIC_APP_URL` is intentionally absent — the app connects Socket.IO to same-origin (a `NEXT_PUBLIC_` host would be baked into the client bundle at build and point phones at the wrong place).
- **Off-box backups are intentionally out of scope** (#7): backups are local (disk or USB) only. Pushing player data off-box (NAS/cloud) is a possible future feature but has data-privacy implications and is a deliberate non-goal for now.
- **Captive portal is DNS-hijack only, no app login.** The box resolves all hotspot DNS to itself so opening any URL shows the app; there is deliberately no sign-in/auth step. The DNS hijack is scoped to the hotspot's shared dnsmasq so it must NOT break the box's own outbound DNS during updates — verify this if changing network setup. True auto-popup behaviour in the OS captive-detection webview may later want a small landing-page handler in the scorer app (probe URLs), but that is not built and not required for the "open browser → app" flow. Disable per-box via `CAPTIVE_PORTAL="no"` in `captive.conf`.

## Rules for changes
- The boot services have an ordering contract: `root` (network/firewall) → `update` (Phase 3 activate + Phase 1 download + start app) → `build` (Phase 2 background build). Preserve `After=`/`Requires=`/`Before=` when editing.
- The app start now lives at the END of `bridge-box-update.sh` (in the trap), not the start. Keep it unconditional — no failure path may skip it. This is a deliberate inversion of the old "start first" order so the network phase can complete before the app runs.
- Only one process should touch `wlan0`/NAT at a time: the update run and the manual maintenance scripts all take `flock` on `.update.lock` (the update service via its own guard, maintenance scripts via `bb_acquire_lock`), and the health check skips while `bridge-box-update.service` is active. Preserve all these guards. Any new script that switches `wlan0` must source `bridge-box-wifi-lib.sh` and take the lock rather than reimplementing the switch.
- `bridge-box-update.sh` sources the lib **non-fatally**: if the lib is missing it defines minimal fallbacks and still boots the app (updates just get skipped). Preserve that — sourcing must never be able to stop the app from starting.
- NAT/port-redirect logic lives only in `bridge-box-nat.sh` (one source of truth); re-apply it (don't inline iptables) if you add code paths that switch `wlan0`.
- **Line endings must be LF.** Scripts run on the Pi; a CRLF shebang (from a Windows/editor checkout) makes direct execution fail with a confusing "command not found". `.gitattributes` forces `eol=lf` on `*.sh`/`*.service`/`*.timer` etc., `install.sh` strips any stray `\r` from scripts, and internal script-to-script calls use `bash <path>` (not bare `<path>`) so they don't depend on the exec bit or shebang. Keep all three when adding scripts.
- Keep the boot-time app start independent of internet — never make app startup depend on a successful WiFi/update step.
- Preserve the atomic release + symlink + rollback pattern for any deployment changes.
- `bridge-box-update.sh` must always end back in hotspot mode — keep the `trap ... EXIT` restore and prefer `exit 0` (stay serving) over `exit 1` for recoverable network/update failures.
- Wrap any network, clone, install, or build step in a `timeout` so a hang can't wedge the boot flow.
- Keep logs bounded (the truncate-on-start guard) so they can't fill the disk over the life of the device.
- The app reads `APP_COMMIT` to display the running version (via `/healthz` and a UI footer). `bridge-box-update.sh` resolves the current release's commit and passes `APP_COMMIT` to PM2 at start, reload, and rollback (`pm2 reload --update-env`). Keep this wired when changing the deploy flow.
- The actual scoring UI/logic belongs in the separate `bridge-box-scorer` repo, not here. That repo documents its own durability/operations notes (`durability-and-operations.md`).
