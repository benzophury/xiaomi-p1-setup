#!/usr/bin/env bash
# Read-only preflight check for the Xiaomi P1 32" setup toolkit.
# Prints a detailed report of the current TV state and what the full run would
# change. Makes NO changes to the TV.
#
# Usage: ./scripts/preflight.sh [--dry-run] [--help|-h]
set -euo pipefail

# ─── Help ─────────────────────────────────────────────────────────────────────
for _a in "$@"; do
    case "$_a" in
        --help|-h)
            cat <<'EOF'
Usage: ./scripts/preflight.sh [--dry-run]

Read-only preflight check. Prints a report of the TV's current state and
what the debloat + configure run would change. Safe to run any time; makes
no changes to the TV.

Options:
  --dry-run   Simulate the check (skips the ADB connection)
  --help, -h  Show this message and exit
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

source_conf

if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "[dry-run] Skipping live ADB checks — showing what would be reported"
else
    require_adb
fi

# ─── Device Info ──────────────────────────────────────────────────────────────
step "Device"
if [[ "$DRY_RUN" != "1" ]]; then
    _model="$(adb_cmd getprop ro.product.model 2>/dev/null | tr -d '\r')"
    _mfr="$(adb_cmd getprop ro.product.manufacturer 2>/dev/null | tr -d '\r')"
    _android="$(adb_cmd getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
    _sdk="$(adb_cmd getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
    _build="$(adb_cmd getprop ro.build.display.id 2>/dev/null | tr -d '\r')"
    _abi="$(adb_cmd getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
    log_info "Manufacturer : ${_mfr}"
    log_info "Model        : ${_model}"
    log_info "Android      : ${_android} (SDK ${_sdk})"
    log_info "Build        : ${_build}"
    log_info "ABI          : ${_abi}"
else
    log_info "Manufacturer : (dry-run)"
    log_info "Model        : (dry-run)"
    log_info "Android      : (dry-run)"
fi

# ─── Current Home Activity ────────────────────────────────────────────────────
step "Home Screen"
if [[ "$DRY_RUN" != "1" ]]; then
    _home="$(adb_cmd cmd package resolve-activity --brief -a android.intent.action.MAIN \
        -c android.intent.category.HOME 2>/dev/null | tail -n1 | tr -d '\r')" || _home="(error)"
    log_info "Current Home : ${_home:-none}"
    if printf '%s' "${_home}" | grep -q "com.spocky.projengmenu"; then
        log_ok "Projectivy Launcher is already the Home activity"
    elif printf '%s' "${_home}" | grep -q "com.google.android.tvlauncher\|com.google.android.apps.tv.launcherx"; then
        log_info "Stock Google TV launcher owns Home"
    elif printf '%s' "${_home}" | grep -q "com.mitv.tvhome"; then
        log_warn "PatchWall launcher owns Home — debloat will disable it after Projectivy takes over"
    fi
else
    log_info "Current Home : (dry-run)"
fi

# ─── Projectivy ───────────────────────────────────────────────────────────────
step "Projectivy Launcher"
if [[ "$DRY_RUN" != "1" ]]; then
    if adb -s "${TV_IP}:${TV_PORT}" shell pm list packages 2>/dev/null \
            | grep -q "^package:com.spocky.projengmenu$"; then
        _pv="$(adb_cmd dumpsys package com.spocky.projengmenu 2>/dev/null \
            | grep 'versionName=' | head -1 | tr -d '\r ' | cut -d= -f2)"
        log_ok "Installed (version: ${_pv:-unknown})"
    else
        log_info "Not installed"
    fi
    if [[ -n "${PROJECTIVY_APK:-}" ]]; then
        log_info "APK configured : ${PROJECTIVY_APK}"
        [[ -f "${PROJECTIVY_APK}" ]] && log_ok "APK file exists" || log_warn "APK file NOT found at ${PROJECTIVY_APK}"
    else
        log_info "PROJECTIVY_APK not set in setup.conf — launcher install will be skipped"
    fi
else
    log_info "(dry-run)"
fi

# ─── Private DNS / NextDNS ────────────────────────────────────────────────────
step "Private DNS / NextDNS"
if [[ "$DRY_RUN" != "1" ]]; then
    _dns_mode="$(adb_cmd settings get global private_dns_mode 2>/dev/null | tr -d '\r')"
    _dns_spec="$(adb_cmd settings get global private_dns_specifier 2>/dev/null | tr -d '\r')"
    log_info "private_dns_mode      : ${_dns_mode:-not set}"
    log_info "private_dns_specifier : ${_dns_spec:-not set}"
    if [[ "${_dns_mode}" == "hostname" ]] && printf '%s' "${_dns_spec}" | grep -q "nextdns.io"; then
        log_ok "NextDNS Private DNS is already configured"
    else
        if [[ -n "${NEXTDNS_ID:-}" ]]; then
            log_info "Will configure: ${NEXTDNS_ID}.dns.nextdns.io"
        else
            log_info "NEXTDNS_ID not set — Private DNS configuration will be skipped"
        fi
    fi
else
    log_info "(dry-run)"
fi

# ─── Animation Scales ─────────────────────────────────────────────────────────
step "Animation Scales"
if [[ "$DRY_RUN" != "1" ]]; then
    for _scale_key in window_animation_scale transition_animation_scale animator_duration_scale; do
        _val="$(adb_cmd settings get global "${_scale_key}" 2>/dev/null | tr -d '\r')"
        log_info "${_scale_key} = ${_val:-not set}"
    done
    log_info "Will set to : ${ANIMATION_SCALE:-0.5} (from setup.conf)"
else
    log_info "(dry-run)"
fi

# ─── setupwraith Wi-Fi check ──────────────────────────────────────────────────
step "setupwraith Wi-Fi Safety Check"
if [[ "$DRY_RUN" != "1" ]]; then
    check_setupwraith
    if [[ "${SKIP_SETUPWRAITH}" == "1" ]]; then
        log_warn "com.google.android.tungsten.setupwraith will be SKIPPED this run"
    else
        log_ok "com.google.android.tungsten.setupwraith safe to disable (if listed)"
    fi
else
    log_info "(dry-run) — would check if setupwraith owns the Wi-Fi network"
fi

# ─── Package counts ───────────────────────────────────────────────────────────
step "Package Impact"
if [[ "$DRY_RUN" != "1" ]]; then
    _total_installed="$(adb -s "${TV_IP}:${TV_PORT}" shell pm list packages 2>/dev/null | wc -l | tr -d ' ')"
    _total_disabled="$(adb -s "${TV_IP}:${TV_PORT}" shell pm list packages -d 2>/dev/null | wc -l | tr -d ' ')"
    log_info "Total installed : ${_total_installed}"
    log_info "Already disabled: ${_total_disabled}"

    # Count packages from packages.txt that would actually be disabled
    _would_disable=0
    _would_skip_keep=0
    _would_skip_never=0
    _would_skip_absent=0
    _would_skip_ota=0

    while IFS= read -r _raw; do
        # Strip comments and whitespace
        _line="$(printf '%s' "$_raw" | sed 's/#.*//; s/[[:space:]]*$//')"
        [[ -z "$_line" ]] && continue
        _pkg="${_line%% *}"
        [[ -z "$_pkg" ]] && continue

        # Skip OTA if DISABLE_OTA is false
        if [[ "$_pkg" == "com.xiaomi.mitv.updateservice" ]] && [[ "${DISABLE_OTA}" != "true" ]]; then
            (( _would_skip_ota++ )) || true
            continue
        fi

        if is_never_disable "$_pkg"; then
            (( _would_skip_never++ )) || true
        elif is_in_keep_list "$_pkg"; then
            (( _would_skip_keep++ )) || true
        elif ! is_package_installed "$_pkg"; then
            (( _would_skip_absent++ )) || true
        else
            (( _would_disable++ )) || true
        fi
    done < "$DATA/packages.txt"

    log_info "Would disable   : ${_would_disable} packages"
    log_info "Skipped (keep)  : ${_would_skip_keep} packages (in KEEP_APPS)"
    log_info "Skipped (safe)  : ${_would_skip_never} packages (in never-disable.txt)"
    log_info "Skipped (absent): ${_would_skip_absent} packages (not installed on this TV)"
    [[ "${_would_skip_ota}" -gt 0 ]] && log_info "Skipped (OTA)   : ${_would_skip_ota} (DISABLE_OTA=false)"
else
    log_info "(dry-run) — would cross-reference packages.txt against pm list packages"
fi

# ─── KEEP_APPS installed? ─────────────────────────────────────────────────────
step "KEEP_APPS Status"
if [[ -n "${KEEP_APPS:-}" ]]; then
    IFS=',' read -ra _keep_arr <<< "${KEEP_APPS}"
    for _kpkg in "${_keep_arr[@]}"; do
        _kpkg="${_kpkg// /}"
        [[ -z "$_kpkg" ]] && continue
        if [[ "$DRY_RUN" == "1" ]]; then
            log_info "(dry-run) ${_kpkg}"
        elif is_package_installed "$_kpkg"; then
            log_ok "${_kpkg} — installed, will be kept"
        else
            log_warn "${_kpkg} — NOT installed on this TV"
        fi
    done
else
    log_info "KEEP_APPS is empty — all packages in packages.txt will be evaluated"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
step "Next Steps"
log_info "  ./scripts/all.sh            — full pass (debloat + launcher + settings)"
log_info "  ./scripts/all.sh --dry-run  — simulate everything, touch nothing"
log_info "  ./scripts/configure.sh      — interactive setup.conf interview"
log_info "  ./scripts/debloat.sh        — debloat only"
log_info "  ./scripts/restore.sh        — undo all changes using the pre-run snapshot"
