#!/usr/bin/env bash
# Interactive configuration interview for the Xiaomi P1 32" setup toolkit.
# Reads the current setup.conf (if any), prompts for any missing or changed
# values, then writes the results back to setup.conf.
#
# Usage: ./scripts/configure.sh [--yes] [--help|-h]
#
#   --yes   Skip all prompts and use existing values from setup.conf as-is.
#           Exits with an error if TV_IP is still empty after sourcing.
set -euo pipefail

# ─── Help ─────────────────────────────────────────────────────────────────────
for _a in "$@"; do
    case "$_a" in
        --help|-h)
            cat <<'EOF'
Usage: ./scripts/configure.sh [--yes]

Interactive interview that writes/updates setup.conf. Safe to re-run at any
time — existing values are shown as defaults.

Options:
  --yes       Skip all prompts; use existing setup.conf values as-is.
              Exits with an error if TV_IP is still empty.
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

ASSUME_YES=0
for _a in "$@"; do
    case "$_a" in
        --yes|-y) ASSUME_YES=1 ;;
    esac
done

# Load existing values as defaults (don't exit on empty TV_IP here)
TV_IP=""
TV_PORT="5555"
NEXTDNS_ID=""
PROJECTIVY_APK=""
KEEP_APPS="com.google.android.youtube.tv,com.netflix.ninja,com.amazon.amazonvideo.livingroom"
ANIMATION_SCALE="0.5"
DISABLE_VOICE="true"
DISABLE_OTA="true"
HDMI_LABELS="HDMI 1=hdmi1,HDMI 2=hdmi2"

if [[ -f "$CONF" ]]; then
    # shellcheck source=../setup.conf
    source "$CONF"
fi

# ─── Prompt helper ────────────────────────────────────────────────────────────
# ask VAR "Question" [default]
# Prints question + current/default, reads input, sets VAR.
# With ASSUME_YES=1 keeps the existing value (or default).
ask() {
    local _varname="$1"
    local _question="$2"
    local _default="${3:-}"
    local _current="${!_varname:-${_default}}"
    if [[ "$ASSUME_YES" == "1" ]]; then
        printf '%s\n' "${!_varname}" > /dev/null 2>&1 || true
        return 0
    fi
    if [[ -n "$_current" ]]; then
        printf "\n${_C_CYAN}%s${_C_RESET} [%s]: " "$_question" "$_current" >&2
    else
        printf "\n${_C_CYAN}%s${_C_RESET}: " "$_question" >&2
    fi
    local _input
    read -r _input
    if [[ -z "$_input" ]]; then
        printf -v "$_varname" '%s' "$_current"
    else
        printf -v "$_varname" '%s' "$_input"
    fi
}

# yn_ask VAR "Question" default(true|false)
# Prompts [y/N] or [Y/n]. Sets VAR to "true" or "false".
yn_ask() {
    local _varname="$1"
    local _question="$2"
    local _default="${3:-true}"
    if [[ "$ASSUME_YES" == "1" ]]; then
        return 0
    fi
    local _prompt
    if [[ "$_default" == "true" ]]; then
        _prompt="[Y/n]"
    else
        _prompt="[y/N]"
    fi
    printf "\n${_C_CYAN}%s${_C_RESET} %s: " "$_question" "$_prompt" >&2
    local _input
    read -r _input
    case "${_input,,}" in
        y|yes) printf -v "$_varname" 'true'  ;;
        n|no)  printf -v "$_varname" 'false' ;;
        *)     printf -v "$_varname" '%s' "$_default" ;;
    esac
}

# ─── Interview ────────────────────────────────────────────────────────────────
step "Xiaomi P1 32\" Setup Configuration"
log_info "Press Enter to accept the shown default. Ctrl-C to abort without saving."

# 1. TV IP
ask TV_IP "TV IP address (Settings → Network → Wi-Fi)"
[[ -n "$TV_IP" ]] || die "TV_IP is required"

# 2. TV Port
ask TV_PORT "ADB port" "5555"

# 3. NextDNS ID
step "NextDNS Private DNS"
log_info "Your NextDNS config ID is the hex string at the top of nextdns.io/setup."
log_info "Leave blank to skip Private DNS configuration."
ask NEXTDNS_ID "NextDNS config ID (e.g. abc123)"

# 4. Projectivy APK
step "Projectivy Launcher (Morphe-patched)"
log_info "See README.md → 'Projectivy + Morphe Patch' for patching instructions."
log_info "Leave blank to skip launcher installation."
ask PROJECTIVY_APK "Path to Morphe-patched Projectivy APK"
if [[ -n "$PROJECTIVY_APK" ]] && [[ ! -f "$PROJECTIVY_APK" ]]; then
    log_warn "File not found: ${PROJECTIVY_APK}"
    log_warn "You can still save this path and place the file there before running launcher.sh"
fi

# 5. Streaming apps to keep
step "Streaming Apps to Keep"
log_info "Current KEEP_APPS: ${KEEP_APPS:-none}"
log_info "These packages will NOT be disabled even if they appear in data/packages.txt."

if [[ "$ASSUME_YES" != "1" ]]; then
    # Try to show which streaming candidates are actually installed (requires adb)
    _streaming_candidates=(
        "com.crunchyroll.crunchyroid:Crunchyroll"
        "com.sonypicturescore:Sony Pictures Core"
        "com.google.android.videos:Google TV / Movies & TV"
        "com.netflix.ninja:Netflix"
        "com.amazon.amazonvideo.livingroom:Amazon Prime Video"
        "com.google.android.youtube.tv:YouTube"
        "com.disney.disneyplus:Disney+"
        "com.apple.tv:Apple TV+"
        "com.hbo.hbomax:HBO Max / Max"
    )
    log_info ""
    log_info "Enter comma-separated package names to keep (or press Enter for current list):"
    log_info "  Currently: ${KEEP_APPS:-none}"
    log_info ""
    log_info "Known streaming packages for reference:"
    for _entry in "${_streaming_candidates[@]}"; do
        _pkg="${_entry%%:*}"
        _label="${_entry#*:}"
        printf "  %-50s %s\n" "$_pkg" "$_label" >&2
    done
    printf "\n${_C_CYAN}%s${_C_RESET} [%s]: " "Comma-separated packages to keep" "${KEEP_APPS}" >&2
    read -r _keep_input
    if [[ -n "$_keep_input" ]]; then
        KEEP_APPS="$_keep_input"
    fi
fi

# 6. Animation speed
step "Animation Speed"
log_info "Controls window and transition animation speed:"
log_info "  0.5 = snappier (recommended)  |  0.0 = instant  |  1.0 = stock"
ask ANIMATION_SCALE "Animation scale" "0.5"
# Validate it looks like a number
if ! printf '%s' "$ANIMATION_SCALE" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
    log_warn "'${ANIMATION_SCALE}' doesn't look like a number — resetting to 0.5"
    ANIMATION_SCALE="0.5"
fi

# 7. Voice assistant
step "Voice Assistant"
yn_ask DISABLE_VOICE "Disable Google Voice Assistant / OK-Google detection?" "${DISABLE_VOICE:-true}"

# 8. OTA updates
step "OTA Updates"
yn_ask DISABLE_OTA "Disable Xiaomi OTA update service?" "${DISABLE_OTA:-true}"
if [[ "$DISABLE_OTA" == "false" ]]; then
    log_warn "com.xiaomi.mitv.updateservice will NOT be disabled. Xiaomi OTA updates remain active."
fi

# 9. HDMI labels
step "HDMI Input Labels (Projectivy)"
log_info "Format: 'Label=input_id,Label 2=input_id2'"
log_info "Run 'adb shell dumpsys tv_input' on the TV to find input IDs."
ask HDMI_LABELS "HDMI labels" "HDMI 1=hdmi1,HDMI 2=hdmi2"

# ─── Save ─────────────────────────────────────────────────────────────────────
step "Saving setup.conf"

cat > "$CONF" <<EOF
# xiaomi-p1-setup configuration — written by scripts/configure.sh
# Edit this file directly or re-run ./scripts/configure.sh at any time.

# ─── TV Connection ────────────────────────────────────────────────────────────
TV_IP="${TV_IP}"
TV_PORT="${TV_PORT}"

# ─── NextDNS / Private DNS ────────────────────────────────────────────────────
NEXTDNS_ID="${NEXTDNS_ID}"

# ─── Projectivy Launcher ──────────────────────────────────────────────────────
PROJECTIVY_APK="${PROJECTIVY_APK}"

# ─── Apps to Keep ─────────────────────────────────────────────────────────────
KEEP_APPS="${KEEP_APPS}"

# ─── UI Animation Speed ───────────────────────────────────────────────────────
ANIMATION_SCALE="${ANIMATION_SCALE}"

# ─── Voice Assistant ──────────────────────────────────────────────────────────
DISABLE_VOICE="${DISABLE_VOICE}"

# ─── OTA Updates ──────────────────────────────────────────────────────────────
DISABLE_OTA="${DISABLE_OTA}"

# ─── HDMI Input Labels (Projectivy) ───────────────────────────────────────────
HDMI_LABELS="${HDMI_LABELS}"
EOF

# Validate the file we just wrote by sourcing it
# shellcheck source=../setup.conf
source "$CONF"

log_ok "Saved: ${CONF}"
log_info ""
log_info "  TV_IP          : ${TV_IP}"
log_info "  NEXTDNS_ID     : ${NEXTDNS_ID:-not set}"
log_info "  PROJECTIVY_APK : ${PROJECTIVY_APK:-not set}"
log_info "  KEEP_APPS      : ${KEEP_APPS:-none}"
log_info "  ANIMATION_SCALE: ${ANIMATION_SCALE}"
log_info "  DISABLE_VOICE  : ${DISABLE_VOICE}"
log_info "  DISABLE_OTA    : ${DISABLE_OTA}"
log_info ""
log_info "Run ./scripts/preflight.sh to verify before making any changes."
