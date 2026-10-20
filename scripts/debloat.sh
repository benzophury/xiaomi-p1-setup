#!/usr/bin/env bash
# Main debloat script for the Xiaomi P1 32" setup toolkit.
# Disables Xiaomi/Google TV bloat, applies privacy settings, configures
# NextDNS Private DNS, and optionally disables the voice assistant.
#
# A recovery snapshot is written BEFORE any change reaches the TV so that
# scripts/restore.sh can put everything back exactly as it was.
#
# Usage: ./scripts/debloat.sh [--dry-run] [--help|-h]
set -euo pipefail

# ─── Help ─────────────────────────────────────────────────────────────────────
for _a in "$@"; do
    case "$_a" in
        --help|-h)
            cat <<'EOF'
Usage: ./scripts/debloat.sh [--dry-run]

Disables bloat packages listed in data/packages.txt, applies settings from
data/settings.txt, configures NextDNS, and optionally disables the voice
assistant — all as defined in setup.conf.

A recovery snapshot is written to ~/.cleanyourtv/ before any command reaches
the TV. Use scripts/restore.sh to undo everything.

Options:
  --dry-run   Print every command that would run; touch nothing on the TV.
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

for _a in "$@"; do
    case "$_a" in
        --dry-run) DRY_RUN=1 ;;
    esac
done

# ─── Step 1: Load config ──────────────────────────────────────────────────────
step "1/9  Loading configuration"
source_conf
log_ok "TV_IP=${TV_IP}  PORT=${TV_PORT}  DRY_RUN=${DRY_RUN}"

# ─── Step 2: ADB connection ───────────────────────────────────────────────────
step "2/9  Verifying ADB connection"
if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "[dry-run] Skipping live ADB check"
else
    require_adb
fi

# ─── Step 3: Validate packages.txt ───────────────────────────────────────────
step "3/9  Validating data/packages.txt"
validate_packages "$DATA/packages.txt"
log_ok "All package names are valid"

# ─── Step 4: setupwraith safety check ────────────────────────────────────────
step "4/9  setupwraith Wi-Fi safety check"
if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "[dry-run] Skipping setupwraith check"
    SKIP_SETUPWRAITH=0
else
    check_setupwraith
fi

# ─── Step 5: Recovery snapshot ───────────────────────────────────────────────
step "5/9  Saving pre-run recovery snapshot"
if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "[dry-run] Would run: TV_HOST=${TV_IP} python3 tools/recovery.py --save data/packages.txt"
else
    TV_HOST="$TV_IP" TV_PORT="$TV_PORT" "$_PY" -I "$TOOLS/recovery.py" \
        --save "$DATA/packages.txt"
    log_ok "Snapshot written to ~/.cleanyourtv/ — use scripts/restore.sh to undo"
fi

# ─── Step 6: Disable packages ────────────────────────────────────────────────
step "6/9  Disabling bloat packages"

_disabled_count=0
_skipped_keep=0
_skipped_never=0
_skipped_absent=0
_skipped_sw=0
_skipped_ota=0

while IFS= read -r _raw; do
    # Strip BOM, carriage return, inline comments, leading/trailing whitespace
    _line="$(printf '%s' "$_raw" | LC_ALL=C sed 's/\r//; s/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$_line" ]] && continue
    _pkg="${_line%% *}"
    [[ -z "$_pkg" ]] && continue

    # Skip OTA updater if DISABLE_OTA is false
    if [[ "$_pkg" == "com.xiaomi.mitv.updateservice" ]] && [[ "${DISABLE_OTA}" != "true" ]]; then
        log_info "  skip (DISABLE_OTA=false)       : ${_pkg}"
        (( _skipped_ota++ )) || true
        continue
    fi

    # Never-disable list always wins
    if is_never_disable "$_pkg"; then
        log_info "  skip (never-disable)           : ${_pkg}"
        (( _skipped_never++ )) || true
        continue
    fi

    # Skip if user wants to keep this app
    if is_in_keep_list "$_pkg"; then
        log_info "  skip (KEEP_APPS)               : ${_pkg}"
        (( _skipped_keep++ )) || true
        continue
    fi

    # Skip setupwraith if it owns Wi-Fi this run
    if [[ "$_pkg" == "com.google.android.tungsten.setupwraith" ]] && [[ "${SKIP_SETUPWRAITH:-0}" == "1" ]]; then
        log_warn "  skip (setupwraith owns Wi-Fi)  : ${_pkg}"
        (( _skipped_sw++ )) || true
        continue
    fi

    # Skip if not installed on this TV
    if [[ "$DRY_RUN" != "1" ]] && ! is_package_installed "$_pkg"; then
        log_info "  skip (not installed)           : ${_pkg}"
        (( _skipped_absent++ )) || true
        continue
    fi

    # Disable!
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "  [dry-run] pm disable-user --user 0 ${_pkg}"
    else
        _result="$(adb -s "${TV_IP}:${TV_PORT}" shell pm disable-user --user 0 "$_pkg" < /dev/null 2>&1 || true)"
        if printf '%s' "$_result" | grep -qi "disabled\|success"; then
            log_ok "  disabled                       : ${_pkg}"
        else
            log_warn "  (may have failed)              : ${_pkg}  →  ${_result}"
        fi
    fi
    (( _disabled_count++ )) || true

done < "$DATA/packages.txt"

log_ok "Packages: disabled=${_disabled_count}  skipped_keep=${_skipped_keep}  skipped_never=${_skipped_never}  skipped_absent=${_skipped_absent}"
[[ "${_skipped_sw}" -gt 0 ]] && log_warn "setupwraith skipped: ${_skipped_sw}"
[[ "${_skipped_ota}" -gt 0 ]] && log_info "OTA updater skipped (DISABLE_OTA=false): ${_skipped_ota}"

# ─── Step 7: Apply settings ───────────────────────────────────────────────────
step "7/9  Applying settings (data/settings.txt)"

while IFS= read -r _raw; do
    _line="$(printf '%s' "$_raw" | sed 's/\r//; s/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$_line" ]] && continue

    # Split into namespace key value
    read -r _ns _key _val <<< "$_line"
    [[ -z "${_ns:-}" || -z "${_key:-}" || -z "${_val:-}" ]] && continue

    # Substitute ANIMATION_SCALE token with the actual value from setup.conf
    if [[ "$_val" == "ANIMATION_SCALE" ]]; then
        _val="${ANIMATION_SCALE:-0.5}"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "  [dry-run] settings put ${_ns} ${_key} ${_val}"
    else
        adb -s "${TV_IP}:${TV_PORT}" shell settings put "$_ns" "$_key" "$_val" 2>/dev/null \
            && log_ok "  settings put ${_ns} ${_key} ${_val}" \
            || log_warn "  failed: settings put ${_ns} ${_key} ${_val}"
    fi
done < "$DATA/settings.txt"

# ─── Step 8: NextDNS Private DNS ─────────────────────────────────────────────
step "8/9  Private DNS / NextDNS"
if [[ -n "${NEXTDNS_ID:-}" ]]; then
    _dot_host="${NEXTDNS_ID}.dns.nextdns.io"
    log_info "Setting Private DNS to: ${_dot_host}"
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "  [dry-run] settings put global private_dns_mode hostname"
        log_warn "  [dry-run] settings put global private_dns_specifier ${_dot_host}"
    else
        adb -s "${TV_IP}:${TV_PORT}" shell settings put global private_dns_mode hostname
        adb -s "${TV_IP}:${TV_PORT}" shell settings put global private_dns_specifier "$_dot_host"
        # Verify it was accepted
        _check="$(adb -s "${TV_IP}:${TV_PORT}" shell settings get global private_dns_specifier 2>/dev/null | tr -d '\r')"
        if [[ "$_check" == "$_dot_host" ]]; then
            log_ok "Private DNS configured: ${_dot_host}"
        else
            log_warn "Private DNS specifier read back as '${_check}' — check manually"
        fi
    fi
else
    log_info "NEXTDNS_ID not set — skipping Private DNS configuration"
fi

# ─── Step 9: Voice assistant ──────────────────────────────────────────────────
step "9/9  Voice Assistant"
if [[ "${DISABLE_VOICE}" == "true" ]]; then
    log_info "Disabling voice interaction service and OK-Google detection…"
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn '  [dry-run] settings put secure voice_interaction_service ""'
        log_warn "  [dry-run] settings put global ok_google_detection_disabled 1"
    else
        # Clear the voice interactor (empty string un-registers it)
        adb -s "${TV_IP}:${TV_PORT}" shell settings put secure voice_interaction_service "" 2>/dev/null || true
        adb -s "${TV_IP}:${TV_PORT}" shell settings put global ok_google_detection_disabled 1 2>/dev/null || true
        log_ok "Voice assistant disabled"
    fi
else
    log_info "DISABLE_VOICE=false — leaving voice assistant untouched"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
step "Debloat complete"
if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "Dry-run mode: no changes were made to the TV"
else
    log_ok "Disabled ${_disabled_count} package(s)"
    log_ok "Settings applied from data/settings.txt"
    [[ -n "${NEXTDNS_ID:-}" ]] && log_ok "NextDNS configured: ${NEXTDNS_ID}.dns.nextdns.io"
    [[ "${DISABLE_VOICE}" == "true" ]] && log_ok "Voice assistant disabled"
    log_info ""
    log_info "Undo at any time: ./scripts/restore.sh"
    [[ -n "${PROJECTIVY_APK:-}" ]] && log_info "Install launcher:  ./scripts/launcher.sh"
fi
