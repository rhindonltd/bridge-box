# Spec for the provisioning repo: initialise & keep the EBU player list up to date

This is a work brief for the **`bridge-box` provisioning repo**. It is written to be handed to that
repo's Kiro; it has the context needed without access to the `bridge-box-scorer` app repo.

## Context

The Bridge Box appliance runs the `bridge-box-scorer` app. Directors search for players by EBU
number/name, so the appliance needs a local copy of the EBU player list in the app's `players.db`
database. That list must be:

1. **initialised** when a new box is first provisioned, and
2. **kept current** over time,

both **outside** the running app, and both driven by the provisioning system's online windows.

The appliance has a single WiFi radio, so it is either serving its own hotspot **or** connected to
the internet — never both at once. The player sync fetches from `ebu.co.uk`, so it needs an
**online window** (the same kind provisioning already uses for `git clone` / `npm ci`). The app
build itself is fully offline (see the offline-build spec) — the player sync is deliberately **not**
part of `npm run build`.

## What the app repo provides (already implemented)

The app ships a compiled, standalone command in the release:

```
dist/sync-players.js
```

It does the **whole** job in one process — download the EBU CSV, parse/validate it, and write it
into `players.db`. Specifically it is:

- **self-migrating** — it runs the players DB migration first, so a box with no `players.db` yet is
  fine (it creates the schema, then fills it);
- **idempotent** — upserts changed rows and prunes players no longer in the EBU file, so repeated
  runs converge the local list to the source;
- **guarded** — if the fetched file is suspiciously small (a truncated/error response) it aborts
  **without** modifying the database;
- **plain node** — runs with the system `node`, no `tsx` and no `npm`, exactly like the app server.

The provisioning side owns only **when** it runs (first-setup + a recurring timer) — not how it
fetches or writes.

## Goal

A freshly provisioned box ends up with a populated `players.db`, and it stays current over time,
with the sync run by provisioning during online windows and never blocking boot on failure.

## Provisioning contract

Run, from the app's release directory as cwd, with only a bare environment:

```
NODE_ENV=production DATABASE_URL=<data dir> \
  node -r ./scripts/allow-server-only.cjs dist/sync-players.js
```

- **`DATABASE_URL`** — the app's data directory (e.g. `/home/bridgebox/data`); the same value the
  app server uses. `players.db` is created/updated inside it. (Default if unset is
  `/home/bridgebox/data`, but set it explicitly to match the deployment.)
- **`-r ./scripts/allow-server-only.cjs`** — required preload shim (same one the server start uses).
  Keep it in the command.
- **Environment:** only `PATH`, `HOME`, `NODE_ENV`, `DATABASE_URL` are needed. No login shell, no
  `.env`, no `npm`.
- **Network:** must run while the box is **online** (it reaches `ebu.co.uk`).
- **Exit code:** `0` = success; non-zero = failure. A failure is safe to retry and leaves the
  existing DB intact (the small-file guard prevents destructive partial syncs).
- **Concurrency:** don't run it concurrently with itself; a timer that skips if the previous run is
  still active is sufficient.

## Tasks

### 1. Initialise on first provisioning
- During first-setup's online window (alongside `git clone` / `npm ci` / build), run the sync command
  once so the box ships with a populated `players.db`.
- **Soft-deferred:** if this initial run fails (no connectivity, EBU down), do **not** fail
  provisioning. The box boots fine with an empty `players.db`; the recurring timer (Task 2) will
  populate it on the next online window. Player search just returns no matches until then.

### 2. Keep it current with a timer
- Install a systemd timer (or cron) that runs the same command during subsequent online windows
  (the app is scheduling-agnostic — pick the cadence that fits the box's connectivity, e.g. daily or
  on each successful online window).
- Give it a sensible `WorkingDirectory=<release dir>` and the bare env above. Log stdout/stderr so
  the "✅ EBU player sync complete — N players." line (or the failure) is captured.
- Ensure retries/backoff on failure; never let a failed or hung sync wedge anything else.

### 3. Point it at the active release
- The command path (`dist/sync-players.js`, `./scripts/allow-server-only.cjs`) is relative to the
  app release directory. If releases are activated by symlink, run from the current release dir so
  the timer follows activations.

## Acceptance criteria
- A freshly provisioned, online box ends up with a populated `players.db` (player search returns
  matches).
- A box provisioned **without** connectivity still boots; a later timer run (once online) populates
  the list.
- The scheduled sync keeps the list current across runs (new players appear, departed players are
  pruned).
- A failed sync run is retried and never blocks boot or other provisioning steps; the previous
  `players.db` is left intact.
- The command runs with plain `node` (no `tsx`, no `npm`) under a bare environment.

## Notes
- The EBU source URL is fixed inside the app; provisioning does not configure it.
- This is separate from the app **build**, which stays fully offline. Only this sync needs the
  network, and only at runtime.
