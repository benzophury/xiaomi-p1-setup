#!/usr/bin/env bash
# Orchestrator: runs the full Xiaomi P1 32" setup sequence in order.
#
#   1. preflight.sh   — read-only report (always)
#   2. configure.sh   — if setup.conf is incomplete, or --configure is passed
#   3. Confirmation prompt
#   4. debloat.sh     — disable bloat, apply settings, NextDNS, voice
#   5. launcher.sh    — install Projectivy (if PROJECTIVY_APK is set)
#   6. Summary
#
# Usage: ./scripts/all.sh [--dry-run] [--configure] [--yes] [--help|-h]
set -euo pipefail

# ─── Help ─────────────────────────────────────────────────────────────────────
for _a in "$@"; do
    case "$_a" in
        --help|-h)
            cat <<'EOF'
Usage: ./scripts/all.sh [OPTIONS]

Runs the full Xiaomi P1 setup sequence:
  1. Preflight report (read-only)
  2. Configure (if needed or --configure is set)
  3. Debloat + settings + NextDNS + voice
  4. Launcher install (if PROJECTIVY_APK is set)

Options:
  --dry-run    Simulate all steps; touch nothing on the TV.
               Passed through to debloat.sh and launcher.sh.
  --configure  Force re-run of configure.sh even if setup.conf is complete.
  --yes, -y    Skip all confirmation prompts (non-interactive mode).
  --help, -h   Show this message and exit.
EOF
            exit 0
            ;;
    esac
done

# ─── Bootstrap ────────────────────────────────────────────────────────────────
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=lib.sh
source scripts/lib.sh

DRY_RUN=0
FORCE_CONFIGURE=0
ASSUME_YES=0

for _a in "$@"; do
    case "$_a" in
        --dry-run)   DRY_RUN=1 ;;
        --configure) FORCE_CONFIGURE=1 ;;
        --yes|-y)    ASSUME_YES=1 ;;
    esac
done

export DRY_RUN ASSUME_YES

_DRY_FLAG=""
[[ "$DRY_RUN" == "1" ]] && _DRY_FLAG="--dry-run"
_YES_FLAG=""
[[ "$ASSUME_YES" == "1" ]] && _YES_FLAG="--yes"

# ─── Banner ───────────────────────────────────────────────────────────────────
printf "\n${_C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_C_RESET}\n" >&2
printf "${_C_BOLD}  Xiaomi P1 32\" Setup Toolkit — Full Run${_C_RESET}\n" >&2
printf "${_C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_C_RESET}\n\n" >&2
[[ "$DRY_RUN" == "1" ]] && log_warn "DRY-RUN MODE: no changes will be made to the TV"

# ─── Step 1: Preflight ────────────────────────────────────────────────────────
step "Phase 1/4  Preflight check"
# shellcheck disable=SC2086
bash scripts/preflight.sh ${_DRY_FLAG}

# ─── Step 2: Configure (if needed) ───────────────────────────────────────────
step "Phase 2/4  Configuration"

# Check if setup.conf exists and TV_IP is set
_needs_configure=0
if [[ ! -f "$CONF" ]]; then
    log_info "setup.conf not found — running configure.sh"
    _needs_configure=1
elif ! grep -qE '^TV_IP="[^"]+"' "$CONF" 2>/dev/null; then
    log_info "TV_IP is not set in setup.conf — running configure.sh"
    _needs_configure=1
elif [[ "$FORCE_CONFIGURE" == "1" ]]; then
    log_info "--configure flag set — re-running configure.sh"
    _needs_configure=1
fi

if [[ "$_needs_configure" == "1" ]]; then
    # shellcheck disable=SC2086
    bash scripts/configure.sh ${_YES_FLAG}
else
    log_ok "setup.conf looks complete (TV_IP is set). Skipping configure."
    log_info "Use --configure to force re-run configure.sh"
fi

# Load final config values for later steps
source_conf

# ─── Step 3: Confirmation ────────────────────────────────────────────────────
step "Phase 3/4  Ready to proceed"
log_info "TV          : ${TV_IP}:${TV_PORT}"
log_info "NextDNS     : ${NEXTDNS_ID:-(not configured)}"
log_info "Projectivy  : ${PROJECTIVY_APK:-(skip)}"
log_info "KEEP_APPS   : ${KEEP_APPS:-(none)}"
log_info "Animations  : ${ANIMATION_SCALE}"
log_info "Disable voice: ${DISABLE_VOICE}"
log_info "Disable OTA : ${DISABLE_OTA}"
log_info ""

if [[ "$DRY_RUN" == "1" ]]; then
    log_warn "[dry-run] Would proceed now — skipping confirmation"
elif [[ "$ASSUME_YES" == "1" ]]; then
    log_info "--yes mode: skipping confirmation"
else
    printf "${_C_YELLOW}Proceed with debloat? This will disable packages on the TV.${_C_RESET}\n" >&2
    printf "${_C_YELLOW}Use scripts/restore.sh to undo at any time.${_C_RESET}\n\n" >&2
    printf "${_C_CYAN}Continue?${_C_RESET} [y/N]: " >&2
    read -r _confirm
    case "${_confirm,,}" in
        y|yes) log_ok "Proceeding…" ;;
        *)
            log_info "Aborted. Run again when ready."
            exit 0
            ;;
    esac
fi

# ─── Step 4: Debloat ──────────────────────────────────────────────────────────
step "Phase 4a/4  Debloat"
# shellcheck disable=SC2086
bash scripts/debloat.sh ${_DRY_FLAG}

# ─── Step 5: Launcher (optional) ─────────────────────────────────────────────
if [[ -n "${PROJECTIVY_APK:-}" ]]; then
    step "Phase 4b/4  Launcher"
    # shellcheck disable=SC2086
    bash scripts/launcher.sh ${_DRY_FLAG}
else
    log_info "PROJECTIVY_APK not set — skipping launcher installation"
    log_info "Set it in setup.conf and run ./scripts/launcher.sh when ready"
fi

# ─── Final summary ────────────────────────────────────────────────────────────
printf "\n${_C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_C_RESET}\n" >&2
if [[ "$DRY_RUN" == "1" ]]; then
    printf "${_C_YELLOW}  DRY RUN COMPLETE — no changes were made${_C_RESET}\n" >&2
else
    printf "${_C_GREEN}  SETUP COMPLETE${_C_RESET}\n" >&2
fi
printf "${_C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_C_RESET}\n\n" >&2

if [[ "$DRY_RUN" != "1" ]]; then
    log_info "What was done:"
    log_info "  • Xiaomi / Google TV bloat disabled"
    log_info "  • Privacy settings applied"
    [[ -n "${NEXTDNS_ID:-}" ]] && log_info "  • NextDNS configured: ${NEXTDNS_ID}.dns.nextdns.io"
    [[ "${DISABLE_VOICE}" == "true" ]] && log_info "  • Voice assistant disabled"
    [[ -n "${PROJECTIVY_APK:-}" ]] && log_info "  • Projectivy Launcher installed"
    log_info ""
    log_info "To undo everything: ./scripts/restore.sh"
    log_info "Recovery snapshot : ~/.cleanyourtv/"
fi
