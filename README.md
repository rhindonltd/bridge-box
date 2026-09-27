Install scripts for BridgeBox on the Raspberry PI

To initialise a new PI (set `BOX_ID` to a stable per-club/box identifier — it's required, and keys
the box's cloud backups so a replacement box with the same `BOX_ID` inherits its data):

```
curl -sSL https://raw.githubusercontent.com/rhindonltd/bridge-box/refs/heads/main/install.sh | BOX_ID=club123 bash -x 2>&1 | tee ~/install.log
```

See `PROVISIONING.md` for the full guide, including optional cloud backup and box-swap steps.