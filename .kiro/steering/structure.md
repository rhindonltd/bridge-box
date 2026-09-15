# Project Structure

This repo is small and flat — it is the provisioning layer, cloned onto the device at `/home/bridgebox/bridge-box`.

> **Hardware note (dual WiFi adapters).** The box has **two** WiFi radios that run concurrently:
> the onboard Broadcom (`brcmfmac`, `AP_IFACE`, default `wlan0`) is a **permanent hotspot**, and a
> USB Ralink **mt7601U** (`CLIENT_IFACE`, default `wlan1`) is the **client/internet** link. Because
> they're independent, the box can be online for updates **without ever dropping the hotspot**.
> Interface names are overridable in box-local `/home/bridgebox/interfaces.conf`
> (`AP_IFACE=`/`CLIENT_IFACE=`). This replaced the earlier single-radio design, so the old
> "online window / shared radio lock / hotspot down-up / brcmfmac settle" machinery is gone (see the
> design-decisions section). AP-facing scripts (NAT, captive portal) must stay pinned to `AP_IFACE`;
> the client scripts (wifi-lib, wifi-ctl) operate on `CLIENT_IFACE` only.

## Files

- `install.sh` — One-time factory installer. Run as the `bridgebox` user on a fresh Pi. Installs system deps + Node.js (NodeSource, `NODE_MAJOR` default 24), configures passwordless sudo helpers, clones this repo and the scorer app, sets up the atomic release layout, and installs/enables the systemd services and timers. **No PM2** — the app runs as a native systemd service.
- `bridge-box-root.service` / `bridge-box-root.sh` — Runs as **root** at boot (before the online-tasks service). Defines the interface roles (`AP_IFACE`/`CLIENT_IFACE`, overridable via `interfaces.conf`), brings up the WiFi hotspot on `AP_IFACE` (per-device password), enables IP forwarding, applies NAT via `bridge-box-nat.sh`, sets the hostname to `bridge`, and — if `wifi.json` is present and `CLIENT_IFACE` exists — connects the **client radio** to the client network and **leaves it up** (best-effort; the box still serves if it fails). The two radios never contend.
- `bridge-box-app.service` / `bridge-box-app-launch.sh` — The scorer app, run as a **native systemd service** (Type=simple, `Restart=always`), supervised directly by systemd (no PM2). The launcher resolves the active release + `APP_COMMIT`, `cd`s to it, and `exec`s the entrypoint (`node dist/server.js`, else `tsx server.ts`) in the foreground so systemd's main PID is the app. Env (NODE_ENV/PORT/HOST/DB paths) comes from the unit. Independent of the update/network flow — stays up regardless of WiFi state.
- `bridge-box-online-tasks.service` / `bridge-box-online-tasks.sh` — **Boot orchestrator** (bridgebox), `After=bridge-box-root`, `Before=bridge-box-app`. Does the **local Phase 3** first (activate a built `pending` release + `systemctl restart bridge-box-app` — no network), then ensures the client link is online and runs the network jobs sequentially (via `bb_run_online_window`, which is now just "ensure online + run"): the update **download job** (`bridge-box-update.sh`), then the **player-sync job** (`bridge-box-player-sync.sh`), then the **movement-sync job** (`bridge-box-movement-sync.sh`). No hotspot cycle, no lock (the hotspot is a separate radio). Skips network jobs if no `wifi.json`. Retired the old `bridge-box-update.service`.
- `bridge-box-update.sh` — The update **download job** (radio-agnostic; assumes it's already online). Phase 1: download a newer release, deploy `.env`, `npm ci` (all while online), flag `.needs_build`. No radio/lock/trap of its own. Run by the orchestrator (and reusable elsewhere).
- `bridge-box-player-sync.sh` / `bridge-box-player-sync.service` — The player-sync **job** (radio-agnostic): runs the app's `dist/sync-players.js` (self-migrating, idempotent, guarded) to refresh the EBU list in `players.db`. The **service** is the manual path (`bridge sync-players`): it ensures the client link is online then runs the job (via `bb_run_online_window`; the hotspot is untouched). **No timer** — sync runs at boot or manually.
- `bridge-box-movement-sync.sh` / `bridge-box-movement-sync.service` — The movement-sync **job** (radio-agnostic), mirroring player-sync: runs the app's `dist/sync-movements.js` (self-migrating, idempotent, guarded) to refresh the movement list. The **service** is the manual path (`bridge sync-movements`): ensures the client link is online then runs the job. **No timer** — runs at boot (sequentially after player-sync) or manually. Logs to `movement-sync.log`.
- `bridge-box-build.service` / `bridge-box-build.sh` — **Phase 2.** Runs as **bridgebox** after the update service, at low CPU/IO priority (`Nice=19`, `IOSchedulingClass=idle`). Builds a downloaded-but-unbuilt release (marked `.needs_build`) with no network activity, then marks it `.built` and points `pending` at it for activation next boot. Power-cut safe: never touches `current`; a half-built release is retried on the next boot.
- `bridge-box-wifi-ctl.sh` — Root-only privileged WiFi control, invoked by unprivileged `bridgebox` callers (boot online tasks AND the scorer app) via the `wifi-ctl.sh` sudo helper, so nobody needs broad NetworkManager rights. **Operates on `CLIENT_IFACE` only** — the hotspot is a separate radio and is never touched. Verbs: `connect` (reads `wifi.json` itself, joins the client network on the client radio); `hotspot` (now just an idempotent "ensure the hotspot is up" safety re-assert); `scan` (emits raw `nmcli device wifi list` output for the app's network picker); `test-connect <ssid> <pass> [hidden]` / `test-cleanup` (app credential-testing against a throwaway `bridge-box-wifi-test` profile pinned to the client radio — never touches the real hotspot/client config). No shared radio lock, no hotspot-down, no brcmfmac settle any more. `os-update`/`node-upgrade` (root) drive nmcli directly instead.
- `bridge-box-nat.sh` — Idempotent NAT/port-redirect script (guest 80/443 → app `APP_PORT`) on the **AP interface**. Applied by `bridge-box-root.sh` (at boot); also exposed via the `apply-nat.sh` sudo helper. Run as root. `IFACE` must be `AP_IFACE`, never the client radio.
- `bridge-box-captive.sh` — Captive-portal DNS hijack. Writes a NetworkManager shared-dnsmasq drop-in (`/etc/NetworkManager/dnsmasq-shared.d/`) that resolves **all** hotspot DNS to the box's own IP, so guests who open any URL land on the app. Scoped to the hotspot (AP interface) only (does not affect the box's own outbound DNS on the client radio). Derives the hotspot IP at runtime; toggle via `captive.conf`. Run as root from `bridge-box-root.sh` before NAT.
- `bridge-box-wifi-lib.sh` — Shared, sourced library of WiFi helpers (`bb_wifi_online`, `bb_connect_wifi`, `bb_have_internet`). Single source of truth for connecting the **client radio** (`CLIENT_IFACE`) to the `wifi.json` network. The former single-radio primitives `bb_acquire_lock`, `bb_return_to_hotspot`, and `bb_run_online_window` remain as **thin compatibility shims** (no-op lock, no-op restore, and "ensure online + run jobs" respectively) so existing callers keep working. Sourced by `bridge-box-root.sh` (boot client bring-up), `bridge-box-online-tasks.sh`, the sync services, `bridge-box-os-update.sh`, and `bridge-box-node-upgrade.sh`.
- `bridge-box-os-update.sh` — **Manual**, admin-run OS maintenance (`apt upgrade`). Deliberately NOT run automatically; see OS-update policy below. Ensures the client radio is online (via the lib) if not already; the hotspot is unaffected. No lock/trap any more.
- `bridge-box-node-upgrade.sh` — **Manual**, admin-run Node.js **major** upgrade (e.g. 22 → 24). Re-points the NodeSource apt repo to a new major and rebuilds the current release against it. See Node policy below. Ensures the client radio is online via the lib; the hotspot is unaffected.
- `bridge-box-healthcheck.service` / `.timer` / `bridge-box-healthcheck.sh` — Periodic watchdog (every ~2 min) that curls the app on `:3000` (health endpoint if available, else root URL) and, if unresponsive twice, `systemctl restart bridge-box-app` (via the `restart-app.sh` sudo helper). Catches the "hung but alive" case (systemd's `Restart=always` only catches a *crashed* process, not a hung one).
- `bridge-box-log-ship.sh` — Incremental **log export**. Uses a saved journald **cursor** so each run only exports app-unit (`bridge-box-app` by default) entries since the last successful run; the cursor advances **only** on a successful export (a failed export is retried, no loss). The destination is a single `sink_export()` function — **currently a LOCAL file sink** (timestamped files under `log-ship/exports/`, retention `EXPORT_KEEP`), so it needs no network and is manual-only (`bridge ship-logs`). Swapping to an off-box HTTPS POST is a one-function change; once it posts off-box it becomes a job in the boot **online window** (never a during-session timer) and carries the same player-data-privacy caveat as off-box backups. Config is box-local `/home/bridgebox/log-ship.conf` (units, dest, future endpoint/token), not in git.
- `bridge-box-backup.service` / `.timer` / `bridge-box-backup.sh` — Hourly SQLite online backup (`sqlite3 .backup`) of **all** databases found recursively under `data/` (the app uses multiple: game-index, per-game, player, settings), preferring a mounted USB stick under `/media/bridgebox`, else `backups/`. Backup filenames encode the relative path so per-game DBs in subdirs don't collide; retains the newest N per database.
- `bridge.sh` — Admin CLI dispatcher, installed as `/usr/local/bin/bridge` (symlink). Subcommands (`status`, `logs`, `restart`, `update-now`, `os-update`, `node-upgrade`, `cleanup-legacy`, `backup-now`, `sync-players`, `sync-movements`, `wifi-scan`, `ship-logs`, `version`, `wifi`, `password`, `reboot`, `help`) are thin wrappers over the scripts/units. App subcommands use `systemctl`/`journalctl` on `bridge-box-app.service`; system ones use sudo. Add new common tasks here rather than making users memorise long paths.
- `bridge-box-deploy-env.sh` — Drops the scorer `.env` into a release dir before building (box-local `scorer.env` if present, else `scorer.env.template`) and ensures `data/`+`data/games/` exist. Called by `install.sh` and `bridge-box-build.sh` before their builds. Single source of truth for supplying build-time env.
- `scorer.env.template` — Template `.env` for the scorer app (gitignored in that repo but needed at build time). Absolute DB paths only; no `NEXT_PUBLIC_APP_URL` (the app uses same-origin for sockets).
- `bridge-box-app-launch.sh` — Foreground launcher used as the app service's `ExecStart` (resolves release + APP_COMMIT + entrypoint, then `exec`s it). (The former PM2 artifacts `main-app.js`/`pm2.json` have been removed.)
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
├── data/                           # app data (DATABASE_URL), SQLite DBs incl. players.db (EBU list)
├── backups/                        # on-disk backups (fallback when no USB)
├── wifi.json                       # user-supplied WiFi config { ssid, password, hidden } (chmod 600)
├── hotspot.conf                    # optional: HOTSPOT_PASS override (else derived from MAC)
├── hotspot-credentials.txt         # generated: effective SSID + password (chmod 600)
├── release.conf                    # optional: RELEASE_REF="<branch|tag>" to pin deploys
├── captive.conf                    # optional: CAPTIVE_PORTAL="no" to disable the portal
├── interfaces.conf                 # optional: AP_IFACE/CLIENT_IFACE overrides (default wlan0/wlan1)
├── scorer.env                      # optional: box-local .env override (else the repo template is used)
├── log-ship.conf                   # optional: log export config (units, dest, future endpoint/token)
├── log-ship/                       # log export state: cursor + exports/ (timestamped export files)
├── .provisioned                    # marker: present only after a successful install
├── .update.lock                    # flock file — now only serialises build vs a manual update-now
└── logs/                           # all script logs (each bounded/auto-truncated)
    ├── root.log                    # bounded (auto-truncated ~5 MB)
    ├── online-tasks.log            # bounded (auto-truncated ~5 MB) — boot network jobs
    ├── update.log                  # bounded (auto-truncated ~5 MB) — download job
    ├── build.log                   # bounded (auto-truncated ~5 MB) — Phase 2 build
    ├── healthcheck.log             # bounded (auto-truncated ~2 MB)
    ├── backup.log                  # bounded (auto-truncated ~2 MB)
    ├── player-sync.log             # bounded (auto-truncated ~2 MB) — EBU player sync
    ├── movement-sync.log           # bounded (auto-truncated ~2 MB) — movement list sync
    └── log-ship.log                # bounded (auto-truncated ~2 MB) — log export runs
```

USB backups (when a stick is mounted): `/media/bridgebox/<mount>/bridge-box-backups/`.

Also installed system-wide:
- `/etc/systemd/system/bridge-box-{root,online-tasks,build,app}.service`
- `/etc/systemd/system/bridge-box-{healthcheck,backup}.service` and `.timer`
- `/etc/systemd/system/bridge-box-player-sync.service` (no timer — manual/boot-window only)
- `/usr/local/bin/bridge` (symlink to `bridge.sh`) — the admin CLI
- `/usr/local/bridgebox/bin/{restart-service,reboot,apply-nat,wifi-ctl}.sh` (root-owned, invoked via sudoers)
- `/etc/sudoers.d/bridgebox`
- `/etc/NetworkManager/dnsmasq-shared.d/010-bridgebox-captive.conf` (captive-portal DNS drop-in)

## Install / provisioning invariants
- `install.sh` is intended to be **safe to re-run** (re-clones, rebuilds, `mkdir -p`, `ln -sfn`, `enable` are idempotent).
- It clears `/home/bridgebox/.provisioned` at the start and writes it only on full success; absence of that marker means "not fully provisioned — re-run rather than trust a reboot."
- It must **not** enable the app services unless `current` points at a successfully built release (guard in step 8), so an interrupted install can't leave a reboot bringing up a crash-looping app.

## App update model (three phases)
Updates are tied to the **power cycle**, not a schedule (the box lives in a cupboard between
sessions, so timers are useless; and the director just unplugs it, so there's no end-of-session
action). The design keeps switch-on-to-game fast while still updating. With the dual-radio setup the
client link is up alongside the hotspot, so the boot network jobs run sequentially (no radio window
to open/close):
- **Phase 3 — LOCAL, first:** the orchestrator first (no network) activates any built
  `pending` release — point `current` at it (old → `previous`), clear `pending`, `systemctl restart
  bridge-box-app`. Runs before the network jobs because it needs no connectivity, and before the app
  so it comes up on the new code (`online-tasks` is `Before=bridge-box-app`).
- **Phase 1 — download job (`bridge-box-update.sh`):** compare the pinned
  `RELEASE_REF` to the **newest downloaded** release (not just `current`); if newer, `git
  clone`+checkout, deploy `.env`, and **`npm ci` WHILE ONLINE** (a new release may change deps, and
  Phase 2 has no network). Only after deps install does it mark `.needs_build`. `npm ci` on a Pi is
  slow, so the window's deadline is generous; nothing user-facing waits (the app is its own service).
- **Phase 2 — background, after boot (`bridge-box-build.service`, NO network):** low-priority
  **`npm run build` only** (deps already installed by Phase 1). On success mark `.built` and set
  `pending`; if `node_modules` is missing it discards the release so Phase 1 re-does it next boot.
  Never touches the running app. Its **build** must itself be offline (fonts self-hosted etc. — see
  the app's offline-build spec).

**Future direction (Option D — not yet implemented):** move the build to **CI** and have the box
download a **prebuilt, compiled artifact** (tarball/release) instead of building on-device. This
eliminates on-device `npm ci`/`npm run build`/`tsx` entirely — faster, more reliable boots, no
compiler/toolchain on the appliance, and Phase 1 becomes a simple "download + verify + set pending"
with Phase 2 dropped. The current on-device build (Option A) is the interim approach; keep changes
compatible with a later switch to downloading artifacts (the atomic release + `current`/`pending`
symlink model already fits this).

Net effect: download+install this session → build in background this session → activate next session. Boot
is fast (no build on the critical path), the hotspot is never disturbed (separate radio), and a
plug-pull at any point is harmless (only `pending`/marker flips are load-bearing; `current` is only
ever moved at the very start of a boot). Invariants to preserve:
- The app's availability is owned by `bridge-box-app.service` (Restart=always), independent of the update flow — the update run can fail entirely and the app keeps serving.
- Never `npm run build` in Phase 1; never do network (`npm ci`, git, WiFi) in `bridge-box-build.sh` (Phase 2 has no network). All network-dependent steps — clone AND `npm ci` — live in Phase 1.
- Only advance `current` via Phase 3 at boot start; never swap it mid-session.

## Design decisions & policies
- **The app runs as a native systemd service (`bridge-box-app.service`), NOT PM2.** This was a deliberate move away from PM2, which caused a long series of systemd-interaction bugs (PM2's daemon inheriting a held flock fd; the daemon being reaped when the launching oneshot's cgroup was torn down; `$HOME`/`PM2_HOME` mismatches making `pm2 status` see nothing; oneshot exit-code loops). systemd is itself a process supervisor, so we use it directly: `Type=simple`, `Restart=always`, `ExecStart` runs `bridge-box-app-launch.sh` which `exec`s the entrypoint in the foreground. This removed that entire class of bugs. **Do not reintroduce PM2.**
- **App start and network tasks are separate concerns/units.** `bridge-box-app.service` owns running the app; `bridge-box-online-tasks.service` owns the boot activate+download+sync. The network flow can fail entirely without affecting app availability. With the dedicated client radio, network tasks no longer disturb the hotspot or the app at all — they still run at boot (before anyone connects) as the natural time, and can also be triggered manually any time.
- **Dual radios: hotspot and client run concurrently.** The onboard Broadcom radio (`AP_IFACE`, default `wlan0`) is a **permanent** hotspot; the USB mt7601U (`CLIENT_IFACE`, default `wlan1`) carries the internet link and is brought up at boot by `bridge-box-root.sh` and left up. Reaching the internet therefore does NOT take the hotspot down, so there is **no online window, no shared radio lock, and no return-to-hotspot dance** — this is the key simplification over the old single-radio design. `bb_run_online_window` survives only as a thin "ensure online + run jobs sequentially" helper (kept so callers don't churn). Adding a boot network task = adding a job to the orchestrator. AP-facing scripts (NAT, captive) stay pinned to `AP_IFACE`; client scripts (wifi-lib, wifi-ctl) to `CLIENT_IFACE`. Interface names are overridable in `interfaces.conf`.
- **Phase-3 app restart must be non-blocking and only-if-running.** `bridge-box-online-tasks` is ordered `Before=bridge-box-app`, so a synchronous `systemctl restart bridge-box-app` from inside it **deadlocks** (the restart job can't run until online-tasks finishes; online-tasks waits on the restart). Fixes, both kept: (1) `restart-app.sh` uses `systemctl restart --no-block` (queue, don't wait); (2) Phase 3 only restarts if the app is already active — at boot the app hasn't started yet (online-tasks runs before it), so the symlink swap alone is enough and it starts fresh on the new release. Symptom if broken: `bridge update-now` hangs at "activate: restarting app service...".
- **No player-sync timer (still).** Player sync (and updates) run at boot (before the app serves anyone) or via a manual `bridge` command. With dual radios these no longer drop the hotspot, so running one mid-session is now *harmless* rather than *forbidden* — but there is still no `bridge-box-player-sync.timer`, because updates are intentionally tied to the power cycle (see the update model) and there's no benefit to a clock-driven sync on a box that's unplugged between sessions.
- **The app entrypoint is picked per release:** `node dist/server.js` (compiled build, preferred), else `tsx server.ts`; the `--require ./scripts/allow-server-only.cjs` shim is included only if present. Once all releases ship `dist/server.js`, the tsx branch can go.
- **No automatic OS updates.** The boot flow does not run `apt upgrade`, so the appliance is predictable and can't be broken by an unattended kernel/firmware change during a club session. Security updates are applied manually and occasionally by an admin via `bridge-box-os-update.sh` when the box has internet. This is a deliberate tradeoff (predictability over automatic patching).
- **Node.js install & upgrades.** Node is installed from the **NodeSource apt repo**, pinned to a major line via `NODE_MAJOR` in `install.sh` (default **24**, current LTS). A routine `apt upgrade` only moves *within* that major (e.g. 24.x.y); it never crosses majors. A **major** bump (e.g. 22 → 24) is a deliberate, hands-on step via `bridge-box-node-upgrade.sh`, which re-points the repo, rebuilds the current release so native modules match, and restarts `bridge-box-app.service`.
- **Hotspot password is a known, posted credential** (#8), because any player in the room must be able to join quickly. Default is `bridgebox`; a club can override it via `HOTSPOT_PASS="..."` in `hotspot.conf`. The effective SSID + password are written to `hotspot-credentials.txt` (chmod 644) so an admin can print them for the table. This is a deliberate usability-over-secrecy choice — the hotspot is local-only and NATs to the app.
- **`wifi.json` is chmod 600** (#9) — it holds the club WiFi password in plaintext.
- **`APP_COMMIT` format** is the 7-char short hash. On a box that has never updated it shows the initial release label `app_initial` until the first successful update (#11) — expected, not a bug.
- **Deploys can be pinned** (#12): `RELEASE_REF` (default `main`) in `release.conf` selects the branch/tag; the update checks out the exact resolved commit. Use a tag for reproducible fleet deployments.
- **The scorer `.env` is supplied by provisioning at build time.** It's gitignored in the app repo but the build (prebuild migration + `next build`) needs it, and each release is a fresh clone, so `bridge-box-deploy-env.sh` writes it into every release dir before building. Values use **absolute** paths (`/home/bridgebox/data`, `.../data/games`) so DBs live outside the pruned release dirs. Precedence: the app treats real env vars as authoritative and `.env` only fills gaps, so the running values come from `bridge-box-app.service`'s `Environment=` (which sets both DB vars, PORT, HOST); the `.env` mainly satisfies the build — keep the two in sync. Box-local override: `/home/bridgebox/scorer.env`. `NEXT_PUBLIC_APP_URL` is intentionally absent — the app connects Socket.IO to same-origin (a `NEXT_PUBLIC_` host would be baked into the client bundle at build and point phones at the wrong place).
- **Off-box backups are intentionally out of scope** (#7): backups are local (disk or USB) only. Pushing player data off-box (NAS/cloud) is a possible future feature but has data-privacy implications and is a deliberate non-goal for now.
- **Captive portal is DNS-hijack only, no app login.** The box resolves all hotspot DNS to itself so opening any URL shows the app; there is deliberately no sign-in/auth step. The DNS hijack is scoped to the hotspot's shared dnsmasq (AP interface) so it must NOT break the box's own outbound DNS on the client radio — verify this if changing network setup. True auto-popup behaviour in the OS captive-detection webview may later want a small landing-page handler in the scorer app (probe URLs), but that is not built and not required for the "open browser → app" flow. Disable per-box via `CAPTIVE_PORTAL="no"` in `captive.conf`.

## Rules for changes
- The boot services have an ordering contract: `root` (hotspot on AP radio + client link on the USB radio + firewall) → `online-tasks` (local Phase-3 activate, then download + player/movement sync over the client radio; `Before=bridge-box-app`) → `app` → `build` (`Requires=/After=bridge-box-online-tasks`, Phase 2 background build). Preserve `After=`/`Requires=`/`Before=` when editing.
- The app is a separate unit (`bridge-box-app.service`, Restart=always); the online-tasks orchestrator and its jobs never start it (only Phase-3 activation restarts it via the sudo helper). Don't move app-starting into the network path.
- **Keep the two radios separate.** AP-facing scripts (`bridge-box-nat.sh`, `bridge-box-captive.sh`, the hotspot bring-up in `bridge-box-root.sh`) must use `AP_IFACE`; client scripts (`bridge-box-wifi-lib.sh`, `bridge-box-wifi-ctl.sh`, the client bring-up in `bridge-box-root.sh`) must use `CLIENT_IFACE`. Never point a client connect at the AP radio (it would take the hotspot down — the very thing this design avoids). New network code should read the roles from `interfaces.conf` (via the `AP_IFACE`/`CLIENT_IFACE` vars), not hardcode `wlan0`/`wlan1`.
- **The hotspot is never taken down.** There is no shared radio lock and no return-to-hotspot step any more. `bb_acquire_lock`/`bb_return_to_hotspot` are no-op shims; `bb_run_online_window` just ensures the client link is online and runs jobs. Don't reintroduce hotspot-down/up logic on the client path. `.update.lock` now only guards the offline build vs a manual `bridge update-now` (build serialisation), not radio access.
- NAT/port-redirect logic lives only in `bridge-box-nat.sh` (one source of truth) and targets `AP_IFACE`; re-apply it via `apply-nat.sh` (don't inline iptables) if you add code paths that need it.
- **`bridge-box-root.service` must NOT auto-restart** (it's `Type=oneshot`, no `Restart=`). It sets up the hotspot once; because the script (re)creates the hotspot connection, a `Restart=on-failure` turned a transient nmcli error into a delete/recreate loop on the AP radio that cascaded into the update service. The script itself retries the hotspot bring-up internally (`bring_up_hotspot`, up to 5 attempts, only recreating if not already active) rather than relying on systemd restarts.
- **Client bring-up is best-effort and must not block boot.** `bridge-box-root.sh` connects the client radio and leaves it up, but a failure there must NOT fail the unit — the box must still serve over the hotspot (offline-first). Wrap client-connect steps so a hang/failure is logged and boot continues.
- **WiFi connect must be non-destructive.** Connect first (nmcli reuses/updates any saved profile); only delete the profile and retry if that first attempt fails. Never `nmcli connection delete` *before* connecting — a transient failure (e.g. NM busy) would then leave the box with no profile AND not connected ("deleted then failed → lost WiFi").
- **App ↔ provisioning networking boundary.** The scorer app (as `bridgebox`) must NOT drive NetworkManager directly (it gets "Not authorized to control networking"). Instead: the app does read-only `nmcli` (diagnostics, `nmcli -t -f ACTIVE,SSID dev wifi`, `connection show`) and `command -v nmcli` **directly** (reads need no auth); for privileged operations it calls `sudo -n /usr/local/bridgebox/bin/wifi-ctl.sh <scan|test-connect|test-cleanup>` (these act on the client radio only); and to *commit* a chosen network it just **writes `wifi.json`** (a plain file write — root brings the client radio onto it at boot). The app never activates the real hotspot/client connections itself. Credential testing uses the throwaway `bridge-box-wifi-test` profile via the helper. This keeps radio ownership with provisioning and `bridgebox` unprivileged for general NM.
- **NetworkManager control needs root; the online-tasks service runs as `bridgebox`.** So `nmcli` connection changes as `bridgebox` fail with "not authorized". The lib (`bridge-box-wifi-lib.sh`) therefore branches on `_bb_is_root`: root callers (`bridge-box-root.sh`, `os-update`/`node-upgrade`, run as root/sudo) drive `nmcli` directly; non-root callers (the online-tasks service) route the privileged client connect through `bridge-box-wifi-ctl.sh` via the fixed-path sudo helper `/usr/local/bridgebox/bin/wifi-ctl.sh {connect|hotspot|scan|test-connect|test-cleanup}` (allowlisted in sudoers). The helper reads `wifi.json` itself so no password is ever on the command line. This mirrors the `apply-nat.sh` privilege-bridge pattern. Symptom if broken: boot-time update logs "not authorized" and downloads nothing, while `bridge-box-os-update.sh` (root) works fine.
- **Line endings must be LF.** Scripts run on the Pi; a CRLF shebang (from a Windows/editor checkout) makes direct execution fail with a confusing "command not found". `.gitattributes` forces `eol=lf` on `*.sh`/`*.service`/`*.timer` etc., `install.sh` strips any stray `\r` from scripts, and internal script-to-script calls use `bash <path>` (not bare `<path>`) so they don't depend on the exec bit or shebang. Keep all three when adding scripts.
- The app (its own service) must be independent of internet/updates — never make app startup depend on a successful WiFi/update step.
- Preserve the atomic release + symlink + rollback pattern for any deployment changes.
- Boot network jobs should prefer `exit 0` (stay serving) over `exit 1` for recoverable network/update failures, so a failed download/sync never wedges the boot flow. (There's no hotspot to restore any more.)
- Wrap any network, clone, install, or build step in a `timeout` so a hang can't wedge the boot flow.
- Keep logs bounded (the truncate-on-start guard) so they can't fill the disk over the life of the device.
- The app reads `APP_COMMIT` to display the running version (via `/healthz` and a UI footer). `bridge-box-app-launch.sh` resolves the current release's commit and exports `APP_COMMIT` before exec-ing the app. Keep this wired when changing the launcher.
- The actual scoring UI/logic belongs in the separate `bridge-box-scorer` repo, not here. That repo documents its own durability/operations notes (`durability-and-operations.md`).
