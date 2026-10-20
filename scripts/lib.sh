#!/usr/bin/env bash
# Shared helpers sourced by all scripts in scripts/.
# Do NOT run this file directly.
#
# Conventions:
#   log_*   → colored output to stderr
#   adb_cmd → wrapper around `adb -s $TV_IP:$TV_PORT shell` with dry-run support
#   tv_py   → wrapper around `python3 tools/tv.py` with TV_HOST/TV_PORT set
#   DRY_RUN=1 → print commands but do not execute them

# ─── Repo root ────────────────────────────────────────────────────────────────
# All scripts cd here so that relative paths (data/, tools/) always resolve.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$ROOT/data"
TOOLS="$ROOT/tools"
CONF="$ROOT/setup.conf"

# ─── Runtime state ────────────────────────────────────────────────────────────
DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
TV_IP=""
TV_PORT="5555"

# ─── ANSI colours ─────────────────────────────────────────────────────────────
_C_RESET='\033[0m'
_C_GREEN='\033[0;32m'
_C_YELLOW='\033[1;33m'
_C_RED='\033[0;31m'
_C_CYAN='\033[0;36m'
_C_BOLD='\033[1m'

log_info()  { printf "${_C_CYAN}[INFO]${_C_RESET}  %s\n"  "$*" >&2; }
log_ok()    { printf "${_C_GREEN}[ OK ]${_C_RESET}  %s\n"  "$*" >&2; }
log_warn()  { printf "${_C_YELLOW}[WARN]${_C_RESET}  %s\n" "$*" >&2; }
log_error() { printf "${_C_RED}[ERR ]${_C_RESET}  %s\n"  "$*" >&2; }
step()      { printf "\n${_C_BOLD}▶ %s${_C_RESET}\n" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# ─── Python interpreter ───────────────────────────────────────────────────────
_PY="$TOOLS/venv/bin/python"
[[ -x "$_PY" ]] || _PY="python3"

# ─── source_conf ──────────────────────────────────────────────────────────────
# Load setup.conf and validate required fields. Exits with a clear message if
# TV_IP is empty.
source_conf() {
    [[ -f "$CONF" ]] || die "setup.conf not found at $CONF — run scripts/configure.sh first"
    # shellcheck source=../setup.conf
    source "$CONF"
    [[ -n "${TV_IP:-}" ]] || die "TV_IP is not set in setup.conf — run scripts/configure.sh or edit $CONF"
    # Normalise booleans: anything that is not exactly "true" becomes "false"
    case "${DISABLE_VOICE:-true}"  in true) DISABLE_VOICE=true  ;; *) DISABLE_VOICE=false  ;; esac
    case "${DISABLE_OTA:-true}"    in true) DISABLE_OTA=true    ;; *) DISABLE_OTA=false    ;; esac
}

# ─── adb_cmd ──────────────────────────────────────────────────────────────────
# Run an ADB shell command on the TV. With DRY_RUN=1 the command is printed
# to stderr but not executed; the function returns 0 so callers don't need
# special-casing.
#
# Usage: adb_cmd <shell-command ...>
adb_cmd() {
    if [[ "$DRY_RUN" == "1" ]]; then
        log_warn "[dry-run] adb -s ${TV_IP}:${TV_PORT} shell $*"
        return 0
    fi
    adb -s "${TV_IP}:${TV_PORT}" shell "$@" < /dev/null
}

# ─── tv_py ────────────────────────────────────────────────────────────────────
# Wrapper around tools/tv.py that sets TV_HOST and TV_PORT from setup.conf.
# All arguments are forwarded to tv.py.
#
# Usage: tv_py [args...]
tv_py() {
    TV_HOST="$TV_IP" TV_PORT="$TV_PORT" "$_PY" -I "$TOOLS/tv.py" "$@"
}

# ─── is_package_installed ─────────────────────────────────────────────────────
# Returns 0 if the package is installed (enabled or disabled) on the TV.
#
# Usage: is_package_installed com.example.pkg
is_package_installed() {
    local pkg="$1"
    adb -s "${TV_IP}:${TV_PORT}" shell pm list packages < /dev/null 2>/dev/null \
        | tr -d '\r' \
        | grep -q "^package:${pkg}$"
}

# ─── is_in_keep_list ──────────────────────────────────────────────────────────
# Returns 0 if $1 appears in the KEEP_APPS CSV from setup.conf.
# KEEP_APPS must already be loaded (source_conf has been called).
#
# Usage: is_in_keep_list com.example.pkg
is_in_keep_list() {
    local pkg="$1"
    local keep_entry
    # Split on commas; strip whitespace around each entry
    IFS=',' read -ra _keep_arr <<< "${KEEP_APPS:-}"
    for keep_entry in "${_keep_arr[@]}"; do
        keep_entry="${keep_entry// /}"
        [[ "$keep_entry" == "$pkg" ]] && return 0
    done
    return 1
}

# ─── is_never_disable ─────────────────────────────────────────────────────────
# Returns 0 if $1 appears in data/never-disable.txt (ignoring comments).
#
# Usage: is_never_disable com.example.pkg
is_never_disable() {
    local pkg="$1"
    local never_file="$DATA/never-disable.txt"
    [[ -f "$never_file" ]] || return 1
    # Strip comments and blank lines; compare on first field only
    grep -v '^[[:space:]]*#' "$never_file" \
        | awk '{print $1}' \
        | grep -qx "$pkg"
}

# ─── validate_packages ────────────────────────────────────────────────────────
# Validates every non-comment, non-blank line in a packages file against the
# Android package name regex. Exits with a descriptive error on the first
# invalid entry.
#
# Usage: validate_packages data/packages.txt
validate_packages() {
    local file="$1"
    [[ -f "$file" ]] || die "package file not found: $file"
    local line_no=0 name bad=0
    while IFS= read -r raw; do
        (( line_no++ )) || true
        # Strip BOM, carriage return, inline comment, leading/trailing whitespace
        local line
        line="$(printf '%s' "$raw" | LC_ALL=C sed 's/\r//; s/^'"$(printf '\xef\xbb\xbf')"'//; s/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue
        name="${line%% *}"   # first whitespace-separated token
        # Android package name: starts with letter or underscore, segments separated by dots
        if ! printf '%s' "$name" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'; then
            log_error "$file:$line_no: not a valid package name: '$name'"
            bad=1
        fi
    done < "$file"
    [[ "$bad" -eq 0 ]] || exit 1
}

# ─── check_setupwraith ────────────────────────────────────────────────────────
# Checks whether com.google.android.tungsten.setupwraith owns the saved Wi-Fi
# network. If it does, prints a yellow warning and exports
# SKIP_SETUPWRAITH=1 so debloat.sh skips that package for this run.
#
# Rationale: Android deletes the Wi-Fi network record the moment setupwraith is
# disabled, dropping the TV off the network (and killing ADB with it). Safe to
# disable only after the network has been forgotten and re-joined in Settings →
# Network & Internet → Wi-Fi (which re-saves it under android.uid.system).
check_setupwraith() {
    SKIP_SETUPWRAITH=0
    local setup_pkg="com.google.android.tungsten.setupwraith"
    # If the package isn't even in our list, no need to check
    if ! grep -q "^${setup_pkg}" "$DATA/packages.txt" 2>/dev/null; then
        return 0
    fi
    log_info "Checking whether setupwraith owns the Wi-Fi network…"
    local wifi_dump owners
    wifi_dump="$(tv_py dumpsys wifi 2>/dev/null)" || wifi_dump=""
    if [[ -z "$wifi_dump" ]]; then
        log_warn "Could not read dumpsys wifi output. Skipping setupwraith to be safe."
        log_warn "Re-run after checking connectivity, or set FORCE_SETUPWRAITH=1 if using Ethernet."
        SKIP_SETUPWRAITH=1
        return 0
    fi
    owners="$(printf '%s\n' "$wifi_dump" | grep -o 'cname=[^ ]*' || true)"
    if [[ -z "$owners" ]]; then
        log_warn "No Wi-Fi network owners found in dumpsys wifi."
        log_warn "Skipping $setup_pkg to be safe (FORCE_SETUPWRAITH=1 to override)."
        SKIP_SETUPWRAITH=1
        return 0
    fi
    if printf '%s\n' "$owners" | grep -q "setupwraith"; then
        printf "${_C_YELLOW}[WARN]  setupwraith owns the saved Wi-Fi network.${_C_RESET}\n" >&2
        printf "${_C_YELLOW}        Disabling it would delete the network and drop the TV off Wi-Fi.${_C_RESET}\n" >&2
        printf "${_C_YELLOW}        On the TV: Settings → Network & Internet → Wi-Fi → forget and re-join.${_C_RESET}\n" >&2
        printf "${_C_YELLOW}        Then run this script again. Skipping setupwraith for this run.${_C_RESET}\n" >&2
        SKIP_SETUPWRAITH=1
    else
        log_ok "setupwraith does not own the Wi-Fi network — safe to disable if listed."
        SKIP_SETUPWRAITH=0
    fi
}

# ─── require_adb ──────────────────────────────────────────────────────────────
# Verifies that adb is in PATH and that the TV is reachable. Exits clearly
# with actionable instructions if not.
require_adb() {
    command -v adb >/dev/null 2>&1 \
        || die "adb not found in PATH. Install Android Platform Tools:\n  https://developer.android.com/tools/releases/platform-tools"

    log_info "Connecting to TV at ${TV_IP}:${TV_PORT}…"
    # Attempt to connect (idempotent if already connected)
    adb connect "${TV_IP}:${TV_PORT}" >/dev/null 2>&1 || true

    local state
    state="$(adb -s "${TV_IP}:${TV_PORT}" get-state 2>/dev/null || echo "unknown")"
    if [[ "$state" != "device" ]]; then
        log_error "ADB connection to ${TV_IP}:${TV_PORT} failed (state: $state)"
        log_error "Make sure:"
        log_error "  1. The TV is on and on the same network"
        log_error "  2. ADB Debugging is enabled: Settings → Device Preferences → Developer options"
        log_error "  3. TV_IP in setup.conf is correct (currently: '${TV_IP}')"
        log_error "  4. You accepted the 'Allow USB debugging?' prompt on the TV"
        exit 1
    fi
    log_ok "Connected: ${TV_IP}:${TV_PORT}"
}
