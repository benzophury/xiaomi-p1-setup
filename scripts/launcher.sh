#!/usr/bin/env bash
# Install and activate the Morphe-patched Projectivy Launcher on the Xiaomi P1.
#
# Push is done via b64push.py (base64-chunked) which works reliably on all
# firmware versions, including those where `adb push` silently truncates files.
#
# The stock launcher is ONLY disabled AFTER Projectivy successfully claims the
# Home intent — never before.
#
# Usage: ./scripts/launcher.sh [--dry-run] [--help|-h]
set -euo pipefail

# ─── Help ─────────────────────────────────────────────────────────────────────
for _a in "$@"; do
    case "$_a" in
        --help|-h)
            cat <<'EOF'
Usage: ./scripts/launcher.sh [--dry-run]

Pushes the Morphe-patched Projectivy APK to the TV, installs it, grants
required permissions, sets it as the Home activity, then (and only then)
disables the stock Google TV launcher.

Requires PROJECTIVY_APK to be set in setup.conf and the file to exist.

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

_PROJECTIVY_PKG="com.spocky.projengmenu"
_PROJECTIVY_ACTIVITY="${_PROJECTIVY_PKG}/.ui.home.HomeActivity"
_REMOTE_APK="/sdcard/projectivy.apk"

# ─── Step 1: Config & checks ─────────────────────────────────────────────────
step "1/9  Loading configuration"
source_conf

if [[ -z "${PROJECTIVY_APK:-}" ]]; then
    die "PROJECTIVY_APK is not set in setup.conf. See README.md → 'Projectivy + Morphe Patch'."
fi
if [[ ! -f "${PROJECTIVY_APK}" ]]; then
    die "APK file not found: ${PROJECTIVY_APK}"
fi
log_ok "APK: ${PROJECTIVY_APK}"

# ─── Step 2: ADB connection ───────────────────────────────────────────────────
step "2/9  Verifying ADB connection"
if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "[dry-run] Skipping live ADB check"
else
    require_adb
fi

# ─── Step 3: Check if already installed (skip if same version) ───────────────
step "3/9  Checking existing Projectivy installation"
_already_installed=0
if [[ "$DRY_RUN" != "1" ]]; then
    if adb -s "${TV_IP}:${TV_PORT}" shell pm list packages 2>/dev/null \
            | grep -q "^package:${_PROJECTIVY_PKG}$"; then
        _tv_ver="$(adb -s "${TV_IP}:${TV_PORT}" shell dumpsys package "${_PROJECTIVY_PKG}" 2>/dev/null \
            | grep 'versionName=' | head -1 | tr -d '\r ' | cut -d= -f2)"
        log_ok "Projectivy is already installed (TV version: ${_tv_ver:-unknown})"
        _already_installed=1
        # Ask whether to reinstall (useful when updating to a new Morphe-patched build)
        if [[ "${ASSUME_YES:-0}" != "1" ]]; then
            printf "\n${_C_CYAN}Reinstall / update Projectivy?${_C_RESET} [y/N]: " >&2
            read -r _reinstall_ans
            case "${_reinstall_ans,,}" in
                y|yes) _already_installed=0; log_info "Will reinstall" ;;
                *)     log_info "Skipping reinstall — using existing installation" ;;
            esac
        else
            log_info "--yes mode: skipping reinstall (already installed)"
        fi
    else
        log_info "Projectivy not installed — will install"
    fi
else
    log_warn "[dry-run] Would check for existing Projectivy installation"
fi

# ─── Step 4: Push APK via b64push.py ─────────────────────────────────────────
step "4/9  Pushing APK to TV (b64push.py)"
if [[ "${_already_installed}" == "0" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "[dry-run] TV_HOST=${TV_IP} python3 tools/b64push.py ${PROJECTIVY_APK} ${_REMOTE_APK}"
    else
        log_info "Transferring APK (this takes a minute for large files)…"
        TV_HOST="$TV_IP" TV_PORT="$TV_PORT" "$_PY" -I "$TOOLS/b64push.py" \
            "${PROJECTIVY_APK}" "${_REMOTE_APK}"
        log_ok "APK transferred to ${_REMOTE_APK}"
    fi
else
    log_info "Skipping push (not reinstalling)"
fi

# ─── Step 5: Install APK ──────────────────────────────────────────────────────
step "5/9  Installing APK"
if [[ "${_already_installed}" == "0" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "[dry-run] pm install -r ${_REMOTE_APK}"
    else
        _install_out="$(adb -s "${TV_IP}:${TV_PORT}" shell pm install -r "${_REMOTE_APK}" 2>&1)"
        if printf '%s' "$_install_out" | grep -qi "success"; then
            log_ok "Projectivy installed: ${_install_out}"
        else
            die "pm install failed: ${_install_out}"
        fi
        # Clean up remote APK
        adb -s "${TV_IP}:${TV_PORT}" shell rm -f "${_REMOTE_APK}" 2>/dev/null || true
    fi
else
    log_info "Skipping install (not reinstalling)"
fi

# ─── Step 6: Grant permissions ────────────────────────────────────────────────
step "6/9  Granting permissions"
_perms=(
    "android.permission.PACKAGE_USAGE_STATS"
    "android.permission.WRITE_SETTINGS"
)
for _perm in "${_perms[@]}"; do
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "[dry-run] pm grant ${_PROJECTIVY_PKG} ${_perm}"
    else
        adb -s "${TV_IP}:${TV_PORT}" shell pm grant "${_PROJECTIVY_PKG}" "${_perm}" 2>/dev/null \
            && log_ok "Granted: ${_perm}" \
            || log_info "  (already granted or not required): ${_perm}"
    fi
done

# ─── Step 7: Set as Home activity ────────────────────────────────────────────
step "7/9  Setting Projectivy as Home activity"
if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "[dry-run] cmd package set-home-activity ${_PROJECTIVY_ACTIVITY}"
else
    adb -s "${TV_IP}:${TV_PORT}" shell cmd package set-home-activity "${_PROJECTIVY_ACTIVITY}" 2>/dev/null \
        || log_warn "set-home-activity returned non-zero (may still have worked)"
    log_ok "Home activity command sent"
fi

# ─── Step 8: Verify home ownership ───────────────────────────────────────────
step "8/9  Verifying Home ownership"
_home_ok=0
if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "[dry-run] Would verify: cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME"
    _home_ok=1  # Optimistically proceed in dry-run
else
    _resolved="$(adb -s "${TV_IP}:${TV_PORT}" shell \
        cmd package resolve-activity --brief -a android.intent.action.MAIN \
        -c android.intent.category.HOME 2>/dev/null | tail -n1 | tr -d '\r')"
    log_info "Resolved Home activity: ${_resolved:-none}"
    if printf '%s' "${_resolved}" | grep -q "${_PROJECTIVY_PKG}"; then
        log_ok "Projectivy successfully owns the Home intent"
        _home_ok=1
    else
        log_warn "Projectivy does NOT own Home yet (resolved: ${_resolved:-none})"
        log_warn "The stock launcher will NOT be disabled."
    fi
fi

# ─── Step 9: Disable stock launcher (only if Projectivy owns Home) ───────────
step "9/9  Disabling stock launcher"
if [[ "${_home_ok}" == "1" ]]; then
    _stock_launchers=(
        "com.google.android.tvlauncher"
        "com.google.android.apps.tv.launcherx"
    )
    for _stock in "${_stock_launchers[@]}"; do
        if [[ "$DRY_RUN" == "1" ]]; then
            log_warn "[dry-run] pm disable-user --user 0 ${_stock}"
        elif adb -s "${TV_IP}:${TV_PORT}" shell pm list packages 2>/dev/null \
                | grep -q "^package:${_stock}$"; then
            _dis_out="$(adb -s "${TV_IP}:${TV_PORT}" shell pm disable-user --user 0 "${_stock}" 2>&1 || true)"
            log_ok "Disabled: ${_stock}  (${_dis_out})"
        else
            log_info "Not installed, skipping: ${_stock}"
        fi
    done

    # Restart Projectivy to take full ownership of Home
    step "Restarting Projectivy"
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "[dry-run] am force-stop ${_PROJECTIVY_PKG}"
        log_warn "[dry-run] am start -n ${_PROJECTIVY_ACTIVITY}"
    else
        adb -s "${TV_IP}:${TV_PORT}" shell am force-stop "${_PROJECTIVY_PKG}" 2>/dev/null || true
        sleep 1
        adb -s "${TV_IP}:${TV_PORT}" shell am start -n "${_PROJECTIVY_ACTIVITY}" 2>/dev/null \
            && log_ok "Projectivy launched" \
            || log_warn "Could not launch Projectivy — press Home on the remote"
    fi
else
    log_warn "Stock launcher NOT disabled (Projectivy did not claim Home)."
    log_warn "Try running this script again, or reboot the TV first."
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
step "Launcher setup complete"
if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "Dry-run mode: no changes were made"
else
    if [[ "${_home_ok}" == "1" ]]; then
        log_ok "Projectivy Launcher is now the default Home screen"
        log_ok "Stock launchers disabled"
    else
        log_warn "Projectivy was installed but is not yet the Home screen"
        log_warn "Run this script again after the TV is rebooted"
    fi
fi
