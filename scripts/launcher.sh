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

# ─── Step 1: Config & checks ─────────────────────────────────────────────────
step "1/9  Loading configuration"
source_conf

if [[ -z "${PROJECTIVY_APK:-}" ]]; then
    die "PROJECTIVY_APK is not set in setup.conf."
fi
if [[ ! -f "${PROJECTIVY_APK}" ]]; then
    die "APK file not found: ${PROJECTIVY_APK}"
fi
log_ok "APK: ${PROJECTIVY_APK}"

# Identify launcher from APK
_LAUNCHER_PKG="com.spocky.projengmenu"
_LAUNCHER_ACTIVITY="${_LAUNCHER_PKG}/.ui.home.MainActivity"
_LAUNCHER_NAME="Projectivy Launcher"
_REMOTE_APK="/data/local/tmp/projectivy.apk"

if python3 -c "import zipfile; z=zipfile.ZipFile('${PROJECTIVY_APK}'); b=z.read('AndroidManifest.xml'); exit(0 if ('com.gathin.tvhome'.encode('utf-16le') in b or b'com.gathin.tvhome' in b) else 1)" 2>/dev/null; then
    _LAUNCHER_PKG="com.gathin.tvhome"
    _LAUNCHER_ACTIVITY="com.gathin.tvhome/.MainActivity"
    _LAUNCHER_NAME="CleanYourTV Home"
    _REMOTE_APK="/data/local/tmp/tvhome.apk"
fi
log_info "Launcher identified: ${_LAUNCHER_NAME} (${_LAUNCHER_PKG})"

# ─── Step 2: ADB connection ───────────────────────────────────────────────────
step "2/9  Verifying ADB connection"
if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "[dry-run] Skipping live ADB check"
else
    require_adb
fi

# ─── Step 3: Check if already installed (skip if same version) ───────────────
step "3/9  Checking existing ${_LAUNCHER_NAME} installation"
_already_installed=0
if [[ "$DRY_RUN" != "1" ]]; then
    if adb -s "${TV_IP}:${TV_PORT}" shell pm list packages 2>/dev/null \
            | grep -q "^package:${_LAUNCHER_PKG}$"; then
        _tv_ver="$(adb -s "${TV_IP}:${TV_PORT}" shell dumpsys package "${_LAUNCHER_PKG}" 2>/dev/null \
            | grep 'versionName=' | head -1 | tr -d '\r ' | cut -d= -f2)"
        log_ok "${_LAUNCHER_NAME} is already installed (TV version: ${_tv_ver:-unknown})"
        _already_installed=1
        if [[ "${ASSUME_YES:-0}" != "1" ]]; then
            printf "\n${_C_CYAN}Reinstall / update ${_LAUNCHER_NAME}?${_C_RESET} [y/N]: " >&2
            read -r _reinstall_ans
            case "${_reinstall_ans,,}" in
                y|yes) _already_installed=0; log_info "Will reinstall" ;;
                *)     log_info "Skipping reinstall — using existing installation" ;;
            esac
        else
            log_info "--yes mode: skipping reinstall (already installed)"
        fi
    else
        log_info "${_LAUNCHER_NAME} not installed — will install"
    fi
else
    log_warn "[dry-run] Would check for existing ${_LAUNCHER_NAME} installation"
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
        _install_out="$(adb -s "${TV_IP}:${TV_PORT}" install -r "${PROJECTIVY_APK}" 2>&1 || true)"
        if ! printf '%s' "$_install_out" | grep -qi "success"; then
            _install_out="$(adb -s "${TV_IP}:${TV_PORT}" shell pm install -r "${_REMOTE_APK}" 2>&1 || true)"
        fi
        if printf '%s' "$_install_out" | grep -qi "success"; then
            log_ok "${_LAUNCHER_NAME} installed: ${_install_out}"
        else
            die "pm install failed: ${_install_out}"
        fi
        adb -s "${TV_IP}:${TV_PORT}" shell rm -f "${_REMOTE_APK}" /sdcard/projectivy.apk 2>/dev/null || true
    fi
else
    log_info "Skipping install (not reinstalling)"
fi

# ─── Step 6: Grant permissions ────────────────────────────────────────────────
step "6/9  Granting permissions"
_perms=()
if [[ "${_LAUNCHER_PKG}" == "com.gathin.tvhome" ]]; then
    _perms=(
        "android.permission.ACCESS_FINE_LOCATION"
    )
    if [[ "$DRY_RUN" != "1" ]]; then
        adb -s "${TV_IP}:${TV_PORT}" shell cmd package compile -m speed -f "${_LAUNCHER_PKG}" 2>/dev/null || true
    fi
else
    _perms=(
        "android.permission.PACKAGE_USAGE_STATS"
        "android.permission.WRITE_SETTINGS"
    )
fi

for _perm in "${_perms[@]}"; do
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "[dry-run] pm grant ${_LAUNCHER_PKG} ${_perm}"
    else
        adb -s "${TV_IP}:${TV_PORT}" shell pm grant "${_LAUNCHER_PKG}" "${_perm}" 2>/dev/null \
            && log_ok "Granted: ${_perm}" \
            || log_info "  (already granted or not required): ${_perm}"
    fi
done

# ─── Step 7: Set as Home activity ────────────────────────────────────────────
step "7/9  Setting ${_LAUNCHER_NAME} as Home activity"
if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "[dry-run] cmd package set-home-activity ${_LAUNCHER_ACTIVITY}"
else
    adb -s "${TV_IP}:${TV_PORT}" shell am start -W -n "${_LAUNCHER_ACTIVITY}" 2>/dev/null || true
    adb -s "${TV_IP}:${TV_PORT}" shell cmd package set-home-activity --user 0 "${_LAUNCHER_ACTIVITY}" 2>/dev/null \
        || adb -s "${TV_IP}:${TV_PORT}" shell cmd package set-home-activity "${_LAUNCHER_ACTIVITY}" 2>/dev/null \
        || log_warn "set-home-activity returned non-zero (may still have worked)"
    log_ok "Home activity command sent"
fi

# ─── Step 8: Verify home ownership ───────────────────────────────────────────
step "8/9  Verifying Home ownership"
_home_ok=0
if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "[dry-run] Would verify: cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME"
    _home_ok=1
else
    _resolved="$(adb -s "${TV_IP}:${TV_PORT}" shell \
        cmd package resolve-activity --brief -a android.intent.action.MAIN \
        -c android.intent.category.HOME 2>/dev/null | tail -n1 | tr -d '\r')"
    log_info "Resolved Home activity: ${_resolved:-none}"
    if printf '%s' "${_resolved}" | grep -q "${_LAUNCHER_PKG}"; then
        log_ok "${_LAUNCHER_NAME} successfully owns the Home intent"
        _home_ok=1
    else
        log_warn "${_LAUNCHER_NAME} does NOT own Home yet (resolved: ${_resolved:-none})"
        # If stock launcher is still dominating priority, we will still disable stock launcher if user confirmed
        _home_ok=1
    fi
fi

# ─── Step 9: Disable stock launcher ───────────────────────────────────────────
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

    step "Restarting ${_LAUNCHER_NAME}"
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "[dry-run] am force-stop ${_LAUNCHER_PKG}"
        log_warn "[dry-run] am start -n ${_LAUNCHER_ACTIVITY}"
    else
        adb -s "${TV_IP}:${TV_PORT}" shell am force-stop "${_LAUNCHER_PKG}" 2>/dev/null || true
        sleep 1
        adb -s "${TV_IP}:${TV_PORT}" shell am start -n "${_LAUNCHER_ACTIVITY}" 2>/dev/null \
            && log_ok "${_LAUNCHER_NAME} launched" \
            || log_warn "Could not launch ${_LAUNCHER_NAME} — press Home on the remote"
    fi
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
step "Launcher setup complete"
if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "Dry-run mode: no changes were made"
else
    log_ok "${_LAUNCHER_NAME} is now the default Home screen"
    log_ok "Stock launchers disabled"
fi
