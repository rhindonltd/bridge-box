# Project Structure

This repo is small and flat — it is the provisioning layer, cloned onto the device at `/home/bridgebox/bridge-box`.

## Files

- `install.sh` — One-time factory installer. Run as the `bridgebox` user on a fresh Pi. Installs system deps + Node.js (NodeSource, `NODE_MAJOR` default 24), configures passwordless sudo helpers, clones this repo and the scorer app, sets up the atomic release layout, and installs/enables the systemd services and timers. **No PM2** — the app runs as a native systemd service.
- `bridge-box-root.service` / `bridge-box-root.sh` — Runs as **root** at boot (before the update service). Brings up the WiFi hotspot (per-device password), enables IP forwarding, applies NAT via `bridge-box-nat.sh`, and sets the hostname to `bridge`.
- `bridge-box-app.service` / `bridge-box-app-launch.sh` — The scorer app, run as a **native systemd service** (Type=simple, `Restart=always`), supervised directly by systemd (no PM2). The launcher resolves the active release + `APP_COMMIT`, `cd`s to it, and `exec`s the entrypoint (`node dist/server.js`, else `tsx server.ts`) in the foreground so systemd's main PID is the app. Env (NODE_ENV/PORT/HOST/DB paths) comes from the unit. Independent of the update/network flow — stays up regardless of WiFi state.
- `bridge-box-online-tasks.service` / `bridge-box-online-tasks.sh` — **Boot orchestrator** (bridgebox), `After=bridge-box-root`, `Before=bridge-box-app`. Fork/join: does the **local Phase 3** first (activate a built `pending` release + `systemctl restart bridge-box-app` — no network), then opens **one** online window via `bb_run_online_window` and runs the network jobs sequentially inside it: the update **download job** (`bridge-box-update.sh`), then the **player-sync job** (`bridge-box-player-sync.sh`), then the **movement-sync job** (`bridge-box-movement-sync.sh`). One hotspot down/up per boot. Skips network jobs if no `wifi.json`. Retired the old `bridge-box-update.service`.
- `bridge-box-update.sh` — The update **download job** (radio-agnostic; assumes it's already online). Phase 1: download a newer release, deploy `.env`, `npm ci` (all while online), flag `.needs_build`. No radio/lock/trap of its own — the online window owns those. Run by the orchestrator (and reusable elsewhere).
- `bridge-box-player-sync.sh` / `bridge-box-player-sync.service` — The player-sync **job** (radio-agnostic): runs the app's `dist/sync-players.js` (self-migrating, idempotent, guarded) to refresh the EBU list in `players.db`. The **service** is the manual path (`bridge sync-players`): it wraps the job in one online window via `bb_run_online_window`. **No timer** — sync only runs in the boot window or manually, never mid-session.
- `bridge-box-movement-sync.sh` / `bridge-box-movement-sync.service` — The movement-sync **job** (radio-agnostic), mirroring player-sync: runs the app's `dist/sync-movements.js` (self-migrating, idempotent, guarded) to refresh the movement list. The **service** is the manual path (`bridge sync-movements`): it wraps the job in one online window via `bb_run_online_window`. **No timer** — runs in the boot online window (sequentially after player-sync) or manually, never mid-session. Logs to `movement-sync.log`.
- `bridge-box-build.service` / `bridge-box-build.sh` — **Phase 2.** Runs as **bridgebox** after the update service, at low CPU/IO priority (`Nice=19`, `IOSchedulingClass=idle`). Builds a downloaded-but-unbuilt release (marked `.needs_build`) with no network activity, then marks it `.built` and points `pending` at it for activation next boot. Power-cut safe: never touches `current`; a half-built release is retried on the next boot.
- `bridge-box-wifi-ctl.sh` — Root-only privileged WiFi control, invoked by unprivileged `bridgebox` callers (boot online window AND the scorer app) via the `wifi-ctl.sh` sudo helper, so nobody needs broad NetworkManager rights. Verbs: `connect`/`hotspot` (boot online window; `connect` reads `wifi.json` itself); `scan` (emits raw `nmcli device wifi list --rescan yes` output for the app's network picker); `test-connect <ssid> <pass> [hidden]` / `test-cleanup` (app credential-testing against a throwaway `bridge-box-wifi-test` profile — never touches the real hotspot/client config). All verbs take the shared `.update.lock` (fd 8), drop the hotspot, and ALWAYS restore it via a trap (single radio). `os-update`/`node-upgrade` (root) drive nmcli directly instead.
- `bridge-box-nat.sh` — Idempotent NAT/port-redirect script (guest 80/443 → app `APP_PORT`). Shared by `bridge-box-root.sh` (at boot) and re-applied after an update cycle via the `apply-nat.sh` sudo helper. Run as root.
- `bridge-box-captive.sh` — Captive-portal DNS hijack. Writes a NetworkManager shared-dnsmasq drop-in (`/etc/NetworkManager/dnsmasq-shared.d/`) that resolves **all** hotspot DNS to the box's own IP, so guests who open any URL land on the app. Scoped to the hotspot only (does not affect the box's own outbound DNS during updates). Derives the hotspot IP at runtime; toggle via `captive.conf`. Run as root from `bridge-box-root.sh` before NAT.
- `bridge-box-wifi-lib.sh` — Shared, sourced library of WiFi helpers (`bb_wifi_online`, `bb_connect_wifi`, `bb_have_internet`, `bb_return_to_hotspot`, `bb_acquire_lock`). Single source of truth for switching `wlan0` to the `wifi.json` client network and returning to hotspot mode. Sourced by **all** scripts that touch the network: `bridge-box-update.sh` (boot), `bridge-box-os-update.sh`, and `bridge-box-node-upgrade.sh`.
- `bridge-box-os-update.sh` — **Manual**, admin-run OS maintenance (`apt upgrade`). Deliberately NOT run automatically; see OS-update policy below. Auto-switches to client WiFi (via the lib) if not already online, then returns to hotspot.
- `bridge-box-node-upgrade.sh` — **Manual**, admin-run Node.js **major** upgrade (e.g. 22 → 24). Re-points the NodeSource apt repo to a new major and rebuilds the current release against it. See Node policy below. Also auto-switches to client WiFi via the lib.
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
├── scorer.env                      # optional: box-local .env override (else the repo template is used)
├── log-ship.conf                   # optional: log export config (units, dest, future endpoint/token)
├── log-ship/                       # log export state: cursor + exports/ (timestamped export files)
├── .provisioned                    # marker: present only after a successful install
├── .update.lock                    # flock file for single-instance update runs
├── root.log                        # bounded (auto-truncated ~5 MB)
├── online-tasks.log                # bounded (auto-truncated ~5 MB) — boot online window
├── update.log                      # bounded (auto-truncated ~5 MB) — download job
├── build.log                       # bounded (auto-truncated ~5 MB) — Phase 2 build
├── healthcheck.log                 # bounded (auto-truncated ~2 MB)
├── backup.log                      # bounded (auto-truncated ~2 MB)
└── player-sync.log                 # bounded (auto-truncated ~2 MB) — EBU player sync
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
action). The design keeps switch-on-to-game fast while still updating:
All network work at boot happens inside **one** online window opened by
`bridge-box-online-tasks.service` (via `bb_run_online_window`) — see the fork/join design decision.
Within that:
- **Phase 3 — LOCAL, before the window:** the orchestrator first (no network) activates any built
  `pending` release — point `current` at it (old → `previous`), clear `pending`, `systemctl restart
  bridge-box-app`. Runs before the window because it needs no connectivity, and before the app so it
  comes up on the new code (`online-tasks` is `Before=bridge-box-app`).
- **Phase 1 — download job, inside the window (`bridge-box-update.sh`):** compare the pinned
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
is fast (no build on the critical path), no WiFi switching while the app runs, and a plug-pull at
any point is harmless (only `pending`/marker flips are load-bearing; `current` is only ever moved
at the very start of a boot). Invariants to preserve:
- The app's availability is owned by `bridge-box-app.service` (Restart=always), independent of the update flow — the update run can fail entirely and the app keeps serving.
- Never `npm run build` in Phase 1; never do network (`npm ci`, git, WiFi) in `bridge-box-build.sh` (Phase 2 has no network). All network-dependent steps — clone AND `npm ci` — live in Phase 1.
- Only advance `current` via Phase 3 at boot start; never swap it mid-session.

## Design decisions & policies
- **The app runs as a native systemd service (`bridge-box-app.service`), NOT PM2.** This was a deliberate move away from PM2, which caused a long series of systemd-interaction bugs (PM2's daemon inheriting a held flock fd; the daemon being reaped when the launching oneshot's cgroup was torn down; `$HOME`/`PM2_HOME` mismatches making `pm2 status` see nothing; oneshot exit-code loops). systemd is itself a process supervisor, so we use it directly: `Type=simple`, `Restart=always`, `ExecStart` runs `bridge-box-app-launch.sh` which `exec`s the entrypoint in the foreground. This removed that entire class of bugs. **Do not reintroduce PM2.**
- **App start and network tasks are separate concerns/units.** `bridge-box-app.service` owns running the app; `bridge-box-online-tasks.service` owns the boot activate+download+sync. The network flow can fail entirely without affecting app availability, and there is no network switching while the app is in use (network tasks run only in the boot window before anyone connects, or by explicit manual command).
- **Fork/join online window.** The single radio means any network task = hotspot down = users disconnected, so all boot network work goes through **one** window (`bb_run_online_window` in the lib): open once (lock → hotspot down → client WiFi), run jobs **sequentially** inside it, close once (hotspot + NAT restored via a guaranteed trap). Adding a network task = adding a job to the orchestrator, NOT a new timer/hotspot cycle. Jobs are radio-agnostic (assume online; no lock/trap of their own). Local-only steps (update Phase 3 activate) run OUTSIDE the window, before it. `bb_run_online_window` is the **single entry point** any new boot/manual network task must use. **Tech-debt (accepted):** `os-update`/`node-upgrade` still hand-wire `bb_acquire_lock`+`bb_wifi_online`+trap rather than using `bb_run_online_window` — fine for now, migrate later.
- **Phase-3 app restart must be non-blocking and only-if-running.** `bridge-box-online-tasks` is ordered `Before=bridge-box-app`, so a synchronous `systemctl restart bridge-box-app` from inside it **deadlocks** (the restart job can't run until online-tasks finishes; online-tasks waits on the restart). Fixes, both kept: (1) `restart-app.sh` uses `systemctl restart --no-block` (queue, don't wait); (2) Phase 3 only restarts if the app is already active — at boot the app hasn't started yet (online-tasks runs before it), so the symlink swap alone is enough and it starts fresh on the new release. Symptom if broken: `bridge update-now` hangs at "activate: restarting app service...".
- **No during-session network switching / no player-sync timer.** Player sync (and updates) must NEVER run on a clock that could fire mid-session and drop users. They run in the boot window (before the app serves anyone) or via a manual `bridge` command (which warns it drops the hotspot). This is why there is no `bridge-box-player-sync.timer`.
- **The app entrypoint is picked per release:** `node dist/server.js` (compiled build, preferred), else `tsx server.ts`; the `--require ./scripts/allow-server-only.cjs` shim is included only if present. Once all releases ship `dist/server.js`, the tsx branch can go.
- **No automatic OS updates.** The boot flow does not run `apt upgrade`, so the appliance is predictable and can't be broken by an unattended kernel/firmware change during a club session. Security updates are applied manually and occasionally by an admin via `bridge-box-os-update.sh` when the box has internet. This is a deliberate tradeoff (predictability over automatic patching).
- **Node.js install & upgrades.** Node is installed from the **NodeSource apt repo**, pinned to a major line via `NODE_MAJOR` in `install.sh` (default **24**, current LTS). A routine `apt upgrade` only moves *within* that major (e.g. 24.x.y); it never crosses majors. A **major** bump (e.g. 22 → 24) is a deliberate, hands-on step via `bridge-box-node-upgrade.sh`, which re-points the repo, rebuilds the current release so native modules match, and restarts `bridge-box-app.service`.
- **Hotspot password is a known, posted credential** (#8), because any player in the room must be able to join quickly. Default is `bridgebox`; a club can override it via `HOTSPOT_PASS="..."` in `hotspot.conf`. The effective SSID + password are written to `hotspot-credentials.txt` (chmod 644) so an admin can print them for the table. This is a deliberate usability-over-secrecy choice — the hotspot is local-only and NATs to the app.
- **`wifi.json` is chmod 600** (#9) — it holds the club WiFi password in plaintext.
- **`APP_COMMIT` format** is the 7-char short hash. On a box that has never updated it shows the initial release label `app_initial` until the first successful update (#11) — expected, not a bug.
- **Deploys can be pinned** (#12): `RELEASE_REF` (default `main`) in `release.conf` selects the branch/tag; the update checks out the exact resolved commit. Use a tag for reproducible fleet deployments.
- **The scorer `.env` is supplied by provisioning at build time.** It's gitignored in the app repo but the build (prebuild migration + `next build`) needs it, and each release is a fresh clone, so `bridge-box-deploy-env.sh` writes it into every release dir before building. Values use **absolute** paths (`/home/bridgebox/data`, `.../data/games`) so DBs live outside the pruned release dirs. Precedence: the app treats real env vars as authoritative and `.env` only fills gaps, so the running values come from `bridge-box-app.service`'s `Environment=` (which sets both DB vars, PORT, HOST); the `.env` mainly satisfies the build — keep the two in sync. Box-local override: `/home/bridgebox/scorer.env`. `NEXT_PUBLIC_APP_URL` is intentionally absent — the app connects Socket.IO to same-origin (a `NEXT_PUBLIC_` host would be baked into the client bundle at build and point phones at the wrong place).
- **Off-box backups are intentionally out of scope** (#7): backups are local (disk or USB) only. Pushing player data off-box (NAS/cloud) is a possible future feature but has data-privacy implications and is a deliberate non-goal for now.
- **Captive portal is DNS-hijack only, no app login.** The box resolves all hotspot DNS to itself so opening any URL shows the app; there is deliberately no sign-in/auth step. The DNS hijack is scoped to the hotspot's shared dnsmasq so it must NOT break the box's own outbound DNS during updates — verify this if changing network setup. True auto-popup behaviour in the OS captive-detection webview may later want a small landing-page handler in the scorer app (probe URLs), but that is not built and not required for the "open browser → app" flow. Disable per-box via `CAPTIVE_PORTAL="no"` in `captive.conf`.

## Rules for changes
- The boot services have an ordering contract: `root` (network/firewall) → `online-tasks` (local Phase-3 activate, then one online window: download + player-sync; `Before=bridge-box-app`) → `app` → `build` (`Requires=/After=bridge-box-online-tasks`, Phase 2 background build). Preserve `After=`/`Requires=`/`Before=` when editing.
- The app is a separate unit (`bridge-box-app.service`, Restart=always); the online-tasks orchestrator and its jobs never start it (only Phase-3 activation restarts it via the sudo helper). Don't move app-starting into the network path.
- Only one process should touch `wlan0`/NAT at a time: all take `flock` on `.update.lock` (`bb_run_online_window` and the maintenance scripts via `bb_acquire_lock`), and the health check skips while `bridge-box-online-tasks.service` **or** `bridge-box-player-sync.service` is active. Preserve all these guards. Any new script that switches `wlan0` must go through `bb_run_online_window` (or at least the lib's helpers), never reimplement the switch.
- `bridge-box-update.sh` sources the lib **non-fatally**: if the lib is missing it defines minimal fallbacks (updates just get skipped). The app is unaffected either way (separate unit).
- NAT/port-redirect logic lives only in `bridge-box-nat.sh` (one source of truth); re-apply it (don't inline iptables) if you add code paths that switch `wlan0`.
- **Single WiFi radio: can't be a hotspot AND join a client network at once.** Before a client connect, the hotspot profile's autoconnect is disabled (it has high priority and would re-steal the radio) and the hotspot brought down, then a rescan; returning to hotspot re-enables autoconnect and brings it back. Symptom if broken: client connect fails with "No network with SSID … found" while the hotspot is up.
- **`bridge-box-root.service` must NOT auto-restart** (it's `Type=oneshot`, no `Restart=`). It sets up the hotspot once; because the script (re)creates the hotspot connection, a `Restart=on-failure` turned a transient nmcli error into a delete/recreate loop that thrashed the single radio and cascaded into the update service. The script itself retries the hotspot bring-up internally (`bring_up_hotspot`, up to 5 attempts, only recreating if not already active) rather than relying on systemd restarts.
- **The Pi's Broadcom WiFi (brcmfmac) needs settle time + scan retries.** Rapidly switching the single radio from AP (hotspot) to client scanning causes `brcmf_escan_timeout` — a failed scan that surfaces as "No network with SSID found". `wifi-ctl.sh` mitigates this: a ~5s settle after taking the hotspot down, then `wait_for_ssid` which rescans up to ~6 times (3s apart) until the target SSID appears before attempting to connect (hidden SSIDs skip the wait). Don't trim these delays/retries — they're load-bearing on real hardware. The whole thing must still fit inside the 90s Phase 1 deadline.
- **WiFi connect must be non-destructive.** Connect first (nmcli reuses/updates any saved profile); only delete the profile and retry if that first attempt fails. Never `nmcli connection delete` *before* connecting — a transient failure (e.g. NM busy) would then leave the box with no profile AND not connected ("deleted then failed → lost WiFi"). Also wait for `wlan0` to leave connecting/deactivating state before connecting, to avoid "New connection activation was enqueued".
- **Network runs must not overlap.** `bridge update-now` runs the online-tasks window and the build strictly sequentially with `--wait`; they share `.update.lock` and the single radio, and overlapping runs cause NM "activation enqueued" errors. The lock inside `bb_run_online_window` enforces single-instance.
- **App ↔ provisioning networking boundary.** The scorer app (as `bridgebox`) must NOT drive NetworkManager directly (it gets "Not authorized to control networking"). Instead: the app does read-only `nmcli` (diagnostics, `nmcli -t -f ACTIVE,SSID dev wifi`, `connection show`) and `command -v nmcli` **directly** (reads need no auth); for privileged operations it calls `sudo -n /usr/local/bridgebox/bin/wifi-ctl.sh <scan|test-connect|test-cleanup>`; and to *commit* a chosen network it just **writes `wifi.json`** (a plain file write — the boot online window connects to it). The app never activates the real hotspot/client connections itself. Credential testing uses the throwaway `bridge-box-wifi-test` profile via the helper. This keeps radio ownership with provisioning and `bridgebox` unprivileged for general NM.
- **NetworkManager control needs root; the boot update service runs as `bridgebox`.** So `nmcli` connection changes as `bridgebox` fail with "not authorized". The lib (`bridge-box-wifi-lib.sh`) therefore branches on `_bb_is_root`: root callers (`os-update`/`node-upgrade`, run via sudo) drive `nmcli` directly; non-root callers (the boot update service) route the privileged connect / return-to-hotspot through `bridge-box-wifi-ctl.sh` via the fixed-path sudo helper `/usr/local/bridgebox/bin/wifi-ctl.sh {connect|hotspot}` (allowlisted in sudoers). The helper reads `wifi.json` itself so no password is ever on the command line. This mirrors the `apply-nat.sh` privilege-bridge pattern. Symptom if broken: boot-time update logs "not authorized" and downloads nothing, while `bridge-box-os-update.sh` (root) works fine.
- **Line endings must be LF.** Scripts run on the Pi; a CRLF shebang (from a Windows/editor checkout) makes direct execution fail with a confusing "command not found". `.gitattributes` forces `eol=lf` on `*.sh`/`*.service`/`*.timer` etc., `install.sh` strips any stray `\r` from scripts, and internal script-to-script calls use `bash <path>` (not bare `<path>`) so they don't depend on the exec bit or shebang. Keep all three when adding scripts.
- The app (its own service) must be independent of internet/updates — never make app startup depend on a successful WiFi/update step.
- Preserve the atomic release + symlink + rollback pattern for any deployment changes.
- `bridge-box-update.sh` must always end back in hotspot mode — keep the `trap ... EXIT` restore and prefer `exit 0` (stay serving) over `exit 1` for recoverable network/update failures.
- Wrap any network, clone, install, or build step in a `timeout` so a hang can't wedge the boot flow.
- Keep logs bounded (the truncate-on-start guard) so they can't fill the disk over the life of the device.
- The app reads `APP_COMMIT` to display the running version (via `/healthz` and a UI footer). `bridge-box-app-launch.sh` resolves the current release's commit and exports `APP_COMMIT` before exec-ing the app. Keep this wired when changing the launcher.
- The actual scoring UI/logic belongs in the separate `bridge-box-scorer` repo, not here. That repo documents its own durability/operations notes (`durability-and-operations.md`).
