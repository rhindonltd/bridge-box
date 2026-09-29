#!/bin/bash
# BridgeBox shared CLOUD backup/restore helpers.
#
# This is the single place that knows about the cloud backup feature: it loads
# the box-local config and performs the entitlement handshake with the vendor's
# HTTPS endpoint. Everything else (tar, upload, download, extract) is dumb
# plumbing living in bridge-box-cloud-backup.sh / bridge-box-cloud-restore.sh —
# exactly the way bridge-box-log-ship.sh isolates its destination behind one
# sink_export() function.
#
# Design invariants (see .kiro/steering):
#   - OPT-IN, OFF BY DEFAULT. No cloud-backup.conf (or missing required keys) =>
#     the feature is disabled and callers no-op, preserving the local-only
#     backup default and the player-data-privacy stance (#7).
#   - NO long-lived AWS keys on the Pi. The only secret on the box is a per-box
#     bearer token; short-lived STS credentials are fetched per run from the
#     entitlement endpoint and exported into the environment for the AWS CLI.
#   - NON-FATAL throughout. Unreachable endpoint / not entitled / offline =>
#     return non-zero and let the caller exit 0 (the box keeps serving).
#   - NEVER log the token or any secret value. Reference secrets by NAME only.
#
# Usage:
#   source /home/bridgebox/bridge-box/bridge-box-cloud-lib.sh
#   bb_cloud_enabled || exit 0                 # feature configured?
#   bb_cloud_entitlement backup || exit 0      # entitled + creds exported?
#   ... aws s3 cp ... using $BB_CLOUD_BUCKET / $BB_CLOUD_PREFIX ...

# ---------------------------------------------------------------------------
# Config contract — box-local /home/bridgebox/cloud-backup.conf (chmod 600, NOT
# in git). Same box-local pattern as wifi.json / scorer.env / log-ship.conf.
#
# Example cloud-backup.conf:
#   # Stable per-club/box identifier. Keys the S3 prefix s3://<bucket>/<BOX_ID>/
#   # A replacement box provisioned with the SAME BOX_ID inherits this data.
#   BOX_ID="club123"
#   # S3 bucket + region that back the fleet (vendor-owned account).
#   CLOUD_BUCKET="bridgebox-backups-prod"
#   CLOUD_REGION="eu-west-2"
#   # Vendor-hosted entitlement endpoint (returns {backup,restore} + STS creds).
#   CLOUD_ENDPOINT="https://eligibility.bridgebox.co.uk/v1/entitlement"
#   # Per-box bearer token that authenticates this box to the endpoint. SECRET.
#   CLOUD_TOKEN="..."
#   # How many snapshots to retain per box in S3 (older ones pruned).
#   SNAPSHOT_KEEP="30"
#
# BOX_ID is written at provisioning time even when the rest is absent (the box
# records who it is); the feature only turns on once bucket + endpoint + token
# are all present.
# ---------------------------------------------------------------------------

# --- Config paths / defaults (callers may pre-set BB_* before sourcing) ---
BB_INSTALL_DIR="${BB_INSTALL_DIR:-/home/bridgebox}"
BB_CLOUD_CONF="${BB_CLOUD_CONF:-$BB_INSTALL_DIR/cloud-backup.conf}"

# Timeout (seconds) around the entitlement HTTP call — a hang must never wedge
# the boot flow (steering: wrap network steps in `timeout`).
BB_CLOUD_HTTP_TIMEOUT="${BB_CLOUD_HTTP_TIMEOUT:-30}"

# Populated by bb_cloud_load_conf. Defaults keep unset access safe under
# `set -u` if a caller inspects them before loading.
BOX_ID="${BOX_ID:-}"
CLOUD_BUCKET="${CLOUD_BUCKET:-}"
CLOUD_REGION="${CLOUD_REGION:-}"
CLOUD_ENDPOINT="${CLOUD_ENDPOINT:-}"
CLOUD_TOKEN="${CLOUD_TOKEN:-}"
SNAPSHOT_KEEP="${SNAPSHOT_KEEP:-30}"

# Outputs of bb_cloud_entitlement (consumed by the backup/restore/log-ship scripts).
BB_CLOUD_BACKUP_OK=""
BB_CLOUD_RESTORE_OK=""
BB_CLOUD_LOGS_OK=""
BB_CLOUD_BUCKET=""
BB_CLOUD_REGION=""
BB_CLOUD_PREFIX=""
# Set to "yes" by bb_cloud_entitlement when the endpoint returns a valid response
# (lets callers tell "endpoint said no" apart from "couldn't reach the endpoint").
BB_CLOUD_ENDPOINT_REACHED=""

# Load the box-local config, if present. Safe under `set -u`. Returns 0 always
# (absence of config is a normal "feature off" state, not an error).
bb_cloud_load_conf() {
    if [ -f "$BB_CLOUD_CONF" ]; then
        # Tighten perms defensively (holds the bearer token).
        chmod 600 "$BB_CLOUD_CONF" 2>/dev/null || true
        # shellcheck disable=SC1090
        . "$BB_CLOUD_CONF"
    fi
    # Normalise defaults after sourcing so downstream reads are safe.
    SNAPSHOT_KEEP="${SNAPSHOT_KEEP:-30}"
    return 0
}

# True (exit 0) only if the feature is fully configured: BOX_ID + bucket +
# endpoint + token all present. A box that only has BOX_ID recorded (bucket /
# endpoint / token not yet supplied) is intentionally "off".
bb_cloud_enabled() {
    bb_cloud_load_conf
    [ -n "${BOX_ID:-}" ] || return 1
    [ -n "${CLOUD_BUCKET:-}" ] || return 1
    [ -n "${CLOUD_ENDPOINT:-}" ] || return 1
    [ -n "${CLOUD_TOKEN:-}" ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# bb_cloud_entitlement <op>       op = "backup" | "restore"
#
# The ONE place that talks to the vendor endpoint. POSTs {box_id, op} with an
# `Authorization: Bearer <CLOUD_TOKEN>` header and parses the JSON response:
#   { "backup": bool, "restore": bool, "logs": bool,
#     "bucket": "...", "region": "...", "prefix": "<box-id>/",
#     "credentials": { "access_key_id","secret_access_key","session_token",... } }
#
# On success for the requested op it:
#   - sets BB_CLOUD_BACKUP_OK / BB_CLOUD_RESTORE_OK / BB_CLOUD_LOGS_OK ("yes"/""),
#   - exports AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN and
#     AWS_DEFAULT_REGION for the AWS CLI,
#   - sets BB_CLOUD_BUCKET / BB_CLOUD_REGION / BB_CLOUD_PREFIX,
#   - returns 0.
# Otherwise (unreachable, non-2xx, not entitled, malformed) it returns non-zero
# and exports NO credentials. Non-fatal: the caller should exit 0.
#
# Secrets: the token is sent only via curl's header; neither it nor the STS
# secret/session values are ever echoed to the log.
# ---------------------------------------------------------------------------
bb_cloud_entitlement() {
    local op="${1:?bb_cloud_entitlement: op (backup|restore|logs) required}"

    case "$op" in
        backup|restore|logs) ;;
        *) echo "cloud: invalid op '$op' (want backup|restore|logs)"; return 1 ;;
    esac

    if ! command -v jq >/dev/null 2>&1; then
        echo "cloud: jq not available — cannot parse entitlement response."
        return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "cloud: curl not available — cannot contact entitlement endpoint."
        return 1
    fi

    # Ensure config is loaded (idempotent).
    bb_cloud_enabled || { echo "cloud: not configured — skipping."; return 1; }

    # Reset the reachability flag; set to "yes" once we get a valid JSON response
    # (lets callers distinguish "endpoint said no" from "couldn't reach it").
    BB_CLOUD_ENDPOINT_REACHED=""

    echo "cloud: requesting '$op' entitlement for BOX_ID=$BOX_ID ..."
    local resp
    # -fsS: fail on HTTP errors, silent progress, show errors. --max-time bounds
    # the whole call; the outer `timeout` is belt-and-braces in case curl hangs
    # before honouring --max-time (e.g. DNS). The token goes in a header only.
    resp="$(timeout "$BB_CLOUD_HTTP_TIMEOUT" curl -fsS \
        --max-time "$BB_CLOUD_HTTP_TIMEOUT" \
        -H "Authorization: Bearer ${CLOUD_TOKEN}" \
        -H "Content-Type: application/json" \
        -X POST "$CLOUD_ENDPOINT" \
        --data-binary "$(jq -n --arg box "$BOX_ID" --arg op "$op" \
            '{box_id:$box, op:$op}')" 2>/dev/null)" || {
        echo "cloud: entitlement endpoint unreachable or returned an error — treating as NOT entitled."
        return 1
    }

    if ! printf '%s' "$resp" | jq empty >/dev/null 2>&1; then
        echo "cloud: entitlement response was not valid JSON — treating as NOT entitled."
        return 1
    fi
    # We got a well-formed response from the endpoint — it's reachable.
    # shellcheck disable=SC2034  # read by sourcing scripts (cloud-backup / log-ship).
    BB_CLOUD_ENDPOINT_REACHED="yes"

    BB_CLOUD_BACKUP_OK=""
    BB_CLOUD_RESTORE_OK=""
    BB_CLOUD_LOGS_OK=""
    [ "$(printf '%s' "$resp" | jq -r '.backup // false')" = "true" ] && BB_CLOUD_BACKUP_OK="yes"
    [ "$(printf '%s' "$resp" | jq -r '.restore // false')" = "true" ] && BB_CLOUD_RESTORE_OK="yes"
    # 'logs' is additive on /v1/ — an older endpoint that omits it just leaves
    # BB_CLOUD_LOGS_OK empty (i.e. not entitled), which is the safe default.
    [ "$(printf '%s' "$resp" | jq -r '.logs // false')" = "true" ] && BB_CLOUD_LOGS_OK="yes"

    # Gate on the specific op requested.
    if [ "$op" = "backup" ] && [ -z "$BB_CLOUD_BACKUP_OK" ]; then
        echo "cloud: box is NOT entitled to backup (backup=false)."
        return 1
    fi
    if [ "$op" = "logs" ] && [ -z "$BB_CLOUD_LOGS_OK" ]; then
        echo "cloud: box is NOT entitled to ship logs (logs=false)."
        return 1
    fi
    if [ "$op" = "restore" ] && [ -z "$BB_CLOUD_RESTORE_OK" ]; then
        echo "cloud: box is NOT entitled to restore (restore=false)."
        return 1
    fi

    # Bucket/region/prefix: prefer the endpoint's values (authoritative), fall
    # back to the box-local config for bucket/region and BOX_ID/ for the prefix.
    BB_CLOUD_BUCKET="$(printf '%s' "$resp" | jq -r --arg b "$CLOUD_BUCKET" '.bucket // $b')"
    BB_CLOUD_REGION="$(printf '%s' "$resp" | jq -r --arg r "$CLOUD_REGION" '.region // $r')"
    BB_CLOUD_PREFIX="$(printf '%s' "$resp" | jq -r --arg p "$BOX_ID/" '.prefix // $p')"

    # Short-lived STS credentials. Export for the AWS CLI. Absence is fatal for
    # a permitted op — without creds we can't touch S3.
    local ak sk st
    ak="$(printf '%s' "$resp" | jq -r '.credentials.access_key_id // empty')"
    sk="$(printf '%s' "$resp" | jq -r '.credentials.secret_access_key // empty')"
    st="$(printf '%s' "$resp" | jq -r '.credentials.session_token // empty')"
    if [ -z "$ak" ] || [ -z "$sk" ] || [ -z "$st" ]; then
        echo "cloud: entitled but endpoint returned no usable credentials — cannot proceed."
        return 1
    fi

    export AWS_ACCESS_KEY_ID="$ak"
    export AWS_SECRET_ACCESS_KEY="$sk"
    export AWS_SESSION_TOKEN="$st"
    export AWS_DEFAULT_REGION="$BB_CLOUD_REGION"

    echo "cloud: entitled for '$op' (bucket=$BB_CLOUD_BUCKET region=$BB_CLOUD_REGION prefix=$BB_CLOUD_PREFIX); short-lived credentials acquired."
    return 0
}

# Clear any exported STS creds from the environment (best-effort tidy-up so a
# long-lived shell doesn't keep them around). Safe to call unconditionally.
bb_cloud_clear_creds() {
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# bb_cloud_write_status <job> <result>
#   Record the outcome of a cloud job so the scorer app can show the director a
#   "last backed up at …" line. <job> is "backup" or "logs"; <result> is one of:
#     ok | skipped_not_configured | not_entitled | offline | error
#
#   Writes /home/bridgebox/cloud-sync-status.json ATOMICALLY (temp + rename), so
#   the app never reads a half-written file. Each job owns only its own section
#   and PRESERVES the other job's section (read-modify-write via jq), so the file
#   is correct no matter which job/trigger last ran. `last_success` only advances
#   on result "ok"; `last_attempt` advances every run. The file lives OUTSIDE
#   data/ on purpose, so it isn't swept into the cloud backup (which would cause
#   a needless upload every run).
#
#   Contract for the app is documented in cloud-sync-app-contract.md. Non-fatal:
#   a failure to write status never affects the job's own exit.
# ---------------------------------------------------------------------------
BB_CLOUD_STATUS_FILE="${BB_CLOUD_STATUS_FILE:-$BB_INSTALL_DIR/cloud-sync-status.json}"

bb_cloud_write_status() {
    local job="$1" result="$2"
    command -v jq >/dev/null 2>&1 || return 0
    case "$job" in backup|logs) ;; *) return 0 ;; esac

    local now existing tmp
    now="$(date -Is 2>/dev/null || date)"
    # Start from the existing file if it's valid JSON, else an empty object.
    if [ -f "$BB_CLOUD_STATUS_FILE" ] && jq empty "$BB_CLOUD_STATUS_FILE" >/dev/null 2>&1; then
        existing="$(cat "$BB_CLOUD_STATUS_FILE")"
    else
        existing='{}'
    fi

    # last_success advances only on "ok"; otherwise carry the previous value.
    local prev_success=""
    prev_success="$(printf '%s' "$existing" | jq -r --arg j "$job" '.[$j].last_success // empty' 2>/dev/null || echo "")"
    local new_success="$prev_success"
    [ "$result" = "ok" ] && new_success="$now"

    tmp="$(mktemp "${BB_CLOUD_STATUS_FILE}.XXXXXX" 2>/dev/null)" || return 0
    if printf '%s' "$existing" | jq \
            --arg j "$job" --arg res "$result" --arg att "$now" \
            --arg suc "$new_success" --argjson en "$(bb_cloud_enabled >/dev/null 2>&1 && echo true || echo false)" \
            '.enabled = $en
             | .[$j] = { last_success: ($suc | select(. != "") // null),
                         last_attempt: $att,
                         last_result: $res }' \
            > "$tmp" 2>/dev/null; then
        mv "$tmp" "$BB_CLOUD_STATUS_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
        chmod 644 "$BB_CLOUD_STATUS_FILE" 2>/dev/null || true
    else
        rm -f "$tmp" 2>/dev/null || true
    fi
    return 0
}
