#!/bin/sh
# shellcheck shell=busybox
# Set up double-dealing-character as a Tailscale exit node. Idempotent, so
# rerun it after a firmware upgrade. It runs on the Brume's BusyBox shell:
#
#   ssh root@double-dealing-character sh -s < double-dealing-character/setup.sh

set -eu
set -o pipefail
if [ "${TRACE-0}" = "1" ]; then
    set -x
fi

GL_TAILSCALE=/usr/bin/gl_tailscale
PATCHED_UP='tailscale up --reset --advertise-exit-node'

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# A fresh Brume booted 16 months behind with NTP never run, which breaks TLS
# to Tailscale's control plane. No real clock predates the firmware build.
sync_clock() {
    firmware_built=$(date -r /etc/glversion +%s)
    [ "$(date +%s)" -ge "$firmware_built" ] && return

    log "Clock is behind the firmware build; syncing NTP"
    /etc/init.d/sysntpd restart
    attempts=30
    while [ "$(date +%s)" -lt "$firmware_built" ]; do
        attempts=$((attempts - 1))
        [ "$attempts" -gt 0 ] || die "NTP didn't sync within 30s"
        sleep 1
    done
}

# Toggling Tailscale in the GL UI didn't save `enabled`, so the init script
# exited without starting tailscaled.
start_tailscale() {
    if [ "$(uci -q get tailscale.settings.enabled)" != "1" ]; then
        log "Enabling Tailscale"
        uci set tailscale.settings.enabled=1
        uci commit tailscale
    fi
    if ! pidof tailscaled >/dev/null; then
        log "Starting tailscaled"
        /etc/init.d/tailscale start
    fi
}

# Interface hotplug scripts run `gl_tailscale restart`, whose
# `tailscale up --reset` drops every flag it doesn't pass.
patch_gl_tailscale() {
    grep -q -F "$PATCHED_UP" "$GL_TAILSCALE" && return

    log "Patching $GL_TAILSCALE to keep --advertise-exit-node"
    sed -i 's/tailscale up --reset/& --advertise-exit-node/' "$GL_TAILSCALE"
    grep -q -F "$PATCHED_UP" "$GL_TAILSCALE" ||
        die "$GL_TAILSCALE has no 'tailscale up --reset' line to patch; read it and update this script"
}

backend_state() {
    tailscale status --json 2>/dev/null | jsonfilter -e '@.BackendState' || true
}

advertise_exit_node() {
    attempts=10
    state=$(backend_state)
    while [ -z "$state" ] || [ "$state" = "NoState" ]; do
        attempts=$((attempts - 1))
        [ "$attempts" -gt 0 ] || die "tailscaled didn't come up within 10s"
        sleep 1
        state=$(backend_state)
    done

    case "$state" in
        Running)
            tailscale set --advertise-exit-node
            ;;
        NeedsLogin)
            log "Open the login URL below, then approve the exit node in the Tailscale console"
            tailscale up --advertise-exit-node
            ;;
        *)
            die "Tailscale is in state $state; expected Running or NeedsLogin"
            ;;
    esac
}

check_exit_node() {
    routes=$(tailscale debug prefs | jsonfilter -e '@.AdvertiseRoutes[*]' || true)
    case "$routes" in
        *0.0.0.0/0*) log "Advertising: $(printf '%s' "$routes" | tr '\n' ' ')" ;;
        *) die "Not advertising an exit node; AdvertiseRoutes is '${routes:-null}'" ;;
    esac
}

main() {
    sync_clock
    start_tailscale
    patch_gl_tailscale
    advertise_exit_node
    check_exit_node
}

main "$@"
