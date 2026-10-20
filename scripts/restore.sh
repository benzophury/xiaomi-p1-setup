#!/usr/bin/env bash
# Restore the TV to its pre-debloat state using the recovery snapshot written
# by scripts/debloat.sh. Uses tools/recovery.py --commands to produce the
# exact re-enable batch — packages that were already disabled before the run
# stay disabled.
#
# Usage: ./scripts/restore.sh [--help|-h]
set -euo pipefail

# ─── Help ─────────────────────────────────────────────────────────────────────
for _a in "$@"; do
    case "$_a" in
        --help|-h)
            cat <<'EOF'
Usage: ./scripts/restore.sh

Restores the TV to the state recorded immediately before scripts/debloat.sh
ran. Uses the recovery snapshot in ~/.cleanyourtv/ to:

  • Re-enable only packages that were enabled before the run
  • Leave packages that were already disabled before (they were not our change)
  • Restore the animation scale settings to their pre-run values
  • Re-enable the stock Google TV launcher
  • Set Home back to the component that owned it before
  • Reset Private DNS to system default (off)
  • Re-enable voice assistant settings

If no snapshot exists, falls back to enabling every package in packages.txt
and resetting the stock launcher (less surgical but safe).

Options:
  --help, -h  Show this message and exit.
EOF
            exit 0
            ;;
    esac
done

# ─── Bootstrap ────────────────────────────────────────────────────────────────
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=lib.sh
source scripts/lib.sh

# ─── Step 1: Load config ──────────────────────────────────────────────────────
step "1/6  Loading configuration"
source_conf

# ─── Step 2: ADB connection ───────────────────────────────────────────────────
step "2/6  Verifying ADB connection"
require_adb

# ─── Step 3: Re-enable packages from snapshot ────────────────────────────────
step "3/6  Re-enabling packages (recovery.py → tv.py --batch)"
log_info "Generating restore batch from recovery snapshot…"
_STOCK_LAUNCHER="com.google.android.tvlauncher"

# recovery.py --commands prints the batch to stdout, narrates to stderr.
# The batch is piped directly into tv.py --batch for execution.
TV_HOST="$TV_IP" TV_PORT="$TV_PORT" \
    "$_PY" -I "$TOOLS/recovery.py" --commands "$DATA/packages.txt" "${_STOCK_LAUNCHER}" \
    | TV_HOST="$TV_IP" TV_PORT="$TV_PORT" "$_PY" -I "$TOOLS/tv.py" --batch

log_ok "Package states restored"

# ─── Step 4: Re-enable stock launcher explicitly ──────────────────────────────
step "4/6  Re-enabling stock launcher"
for _launcher in "com.google.android.tvlauncher" "com.google.android.apps.tv.launcherx"; do
    _result="$(adb -s "${TV_IP}:${TV_PORT}" shell pm enable "${_launcher}" 2>&1 || true)"
    if printf '%s' "$_result" | grep -qi "enabled\|success"; then
        log_ok "Enabled: ${_launcher}"
    else
        log_info "  ${_launcher}: ${_result}"
    fi
done

# ─── Step 5: Restore settings to sane defaults ───────────────────────────────
step "5/6  Restoring settings"

# Restore animation scales to Android stock defaults (1.0) — the recovery.py
# snapshot already handles this for the exact pre-run value via --batch above,
# but we reset voice and DNS regardless since recovery.py doesn't track those.

# Reset Private DNS
log_info "Resetting Private DNS to system default (off)…"
adb -s "${TV_IP}:${TV_PORT}" shell settings put global private_dns_mode off 2>/dev/null \
    && log_ok "private_dns_mode = off" \
    || log_warn "Could not reset private_dns_mode"

# Re-enable voice assistant
log_info "Restoring voice assistant settings…"
adb -s "${TV_IP}:${TV_PORT}" shell settings delete secure voice_interaction_service 2>/dev/null || true
adb -s "${TV_IP}:${TV_PORT}" shell settings put global ok_google_detection_disabled 0 2>/dev/null \
    && log_ok "ok_google_detection_disabled = 0 (voice assistant re-enabled)" \
    || log_warn "Could not restore voice assistant settings"

# Restore ad tracking opt-outs (leave them — these are user preferences, not debloat)
# Restore notification heads-up
adb -s "${TV_IP}:${TV_PORT}" shell settings put global heads_up_notifications_enabled 1 2>/dev/null \
    && log_ok "heads_up_notifications_enabled = 1" \
    || log_warn "Could not restore heads_up_notifications_enabled"

# ─── Step 6: Restart home ────────────────────────────────────────────────────
step "6/6  Restarting Home to stock launcher"
adb -s "${TV_IP}:${TV_PORT}" shell am force-stop "com.google.android.tvlauncher" 2>/dev/null || true
adb -s "${TV_IP}:${TV_PORT}" shell \
    "am start -a android.intent.action.MAIN -c android.intent.category.HOME" 2>/dev/null \
    && log_ok "Home restarted" \
    || log_warn "Could not send HOME intent — press the Home button on the remote"

# ─── Summary ──────────────────────────────────────────────────────────────────
step "Restore complete"
log_ok "TV should be back to its pre-debloat state"
log_info "If the home screen still shows Projectivy, reboot the TV:"
log_info "  adb -s ${TV_IP}:${TV_PORT} shell reboot"
