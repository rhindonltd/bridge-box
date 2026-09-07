# Product

BridgeBox is a self-contained Raspberry Pi appliance for scoring bridge (the card game) at a club or event, with no internet required to operate.

This repository (`bridge-box`) is the **provisioning and lifecycle layer** for the appliance. It does not contain the scoring application itself — that lives in a separate repo, `bridge-box-scorer` (a Next.js app). This repo handles:

- **Factory install** — turning a fresh Raspberry Pi into a BridgeBox (`install.sh`).
- **Network setup** — running the Pi as a self-hosted WiFi hotspot (SSID `BridgeBox-XXXX`) so users can connect directly and reach the app, with NAT redirecting ports 80/443 to the app on port 3000.
- **App lifecycle** — starting the scorer app immediately in hotspot mode, then optionally connecting to a real WiFi network (configured via `wifi.json`) to pull and atomically deploy app updates.

## Key behaviors to keep in mind

- The device must be **usable offline first**. The app starts before any internet connectivity is attempted.
- Updates are **atomic and reversible**: each release is a timestamped/commit-named directory, `current` is a symlink, and a `previous` symlink enables rollback if a build or reload fails.
- The device is accessed by non-technical club users, so behavior should be resilient and self-recovering (services use `Restart=on-failure`).
