#!/bin/sh
###############################################################################
# mango-tailscale-setup.sh
#
# Set up a GL.iNet GL-MT300N-V2 (Mango) as a Tailscale exit node, with the
# Tailscale binaries and state living on a USB drive (because internal flash
# is too small to hold them).
#
# ---- Background ------------------------------------------------------------
#
# The Mango is explicitly NOT on GL.iNet's supported-model list for the
# built-in Tailscale integration [1], and even on supported hardware that
# integration doesn't expose exit-node functionality [1, 6]. So this script
# does a fully manual install and sidesteps both limitations.
#
# Pat Regan documents the storage problem plainly: running Tailscale on the
# Mango is a hack because the Mango doesn't have enough flash to even hold
# Tailscale [7]. Every working community recipe routes around this by putting
# the binaries on external storage. This script follows the bitsnbobs Mango
# tutorial [2] and Maigre GL.iNet gist [8] for the USB pattern, plus the
# Gad-Elrab writeup [5] for the firewall/NAT reasoning.
#
# ---- Operating mode --------------------------------------------------------
#
# Assumes the Mango is configured as a wifi REPEATER against a home wifi
# network. The upstream interface is `wwan`, which GL.iNet firmware places
# in the `wan` firewall zone alongside the physical WAN port. The exit node
# routes remote tailnet peers' internet traffic through the home connection.
#
# Expected throughput: ~5-10 Mbps. Two compounding effects: the Mango has
# no AES offload on a single ~580 MHz MIPS core [7], and double-NAT (Mango
# behind home router, no port-forward) usually means peers connect via DERP
# relay rather than directly. Forwarding UDP 41641 on the home router to
# the Mango helps significantly.
#
# ---- Design ----------------------------------------------------------------
#
# POSIX sh (busybox-safe). Each subcommand is idempotent so partial failures
# don't require manual cleanup. Destructive operations (format-usb) require
# an explicit --yes-wipe flag. See `help` subcommand for usage.
#
# ---- References ------------------------------------------------------------
#
# [1] GL.iNet Router Docs 4 - Tailscale (unsupported-model list incl. Mango,
#     no UI exit-node toggle):
#     https://docs.gl-inet.com/router/en/4/interface_guide/tailscale/
# [2] bitsnbobs - Running Tailscale on a Mango Router (canonical Mango
#     install via USB):
#     https://bitsnbobs.kertho.me/en/posts/running-tailscale-on-a-mango-router/
# [3] UncleSam1966/Tailscale-Setup (scripted install, tested on Mango):
#     https://github.com/UncleSam1966/Tailscale-Setup
# [4] Tailscale static packages index (mipsle binaries, JSON manifest):
#     https://pkgs.tailscale.com/stable/?mode=json
# [5] Mohamed Gad-Elrab - How I Routed All My GL.iNet MT3000 Traffic Through
#     a Remote Tailscale Exit Node (NAT/forward rules explanation):
#     https://medium.com/@mhmgad/how-i-routed-all-my-gl-inet-f73562150fff
# [6] GL.iNet Forum - How to Configure GL.iNet Router to host Tailscale Exit
#     Node (SSH procedure for --advertise-exit-node):
#     https://forum.gl-inet.com/t/how-to-configure-gl-inet-router-to-host-tailscale-exit-node/65958
# [7] Pat Regan - OpenWRT, Two GL.iNet Routers, and Tailscale: Successes and
#     Failures (Mango exit-node firsthand experience, throughput, ephemeral
#     logs warning):
#     https://blog.patshead.com/2022/10/openwrt-gl-dot-inet-tailscale-successes-and-failures.html
# [8] Maigre gist - Install Tailscale on GL.iNET router, using microSD/USB
#     storage:
#     https://gist.github.com/Maigre/3f51f3a22def14e88a8f3e585e2a9d65
# [9] OpenWrt Forum - Help to configure tailscale as a proxy service
#     (GL-MT300N-V2 with vanilla OpenWrt 22.03):
#     https://forum.openwrt.org/t/help-to-configure-tailscale-as-a-proxy-service/142428
###############################################################################

set -eu

# === Configuration (override via environment) ===
USB_DEV="${USB_DEV:-/dev/sda}"
USB_PART="${USB_PART:-/dev/sda1}"
USB_MOUNT="${USB_MOUNT:-/mnt/sda1}"
TS_BASE="$USB_MOUNT/opt/tailscale"
TS_HOSTNAME="${TS_HOSTNAME:-mango-exit}"

# === Output helpers ===
log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# === Helpers ===

# ensure_pkg <binary> <package>  - install package only if binary missing
ensure_pkg() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log "Installing missing package: $2"
        opkg list-installed >/dev/null 2>&1 || opkg update
        opkg install "$2"
    fi
}

usb_fs_type() {
    mount | awk -v m="$USB_MOUNT" '$3 == m {
        for (i = 1; i <= NF; i++) if ($i == "type") print $(i + 1)
    }'
}

# Refuse to write to USB unless it is mounted AND on a POSIX filesystem.
#
# Two failure modes this guards against:
#  1. USB not mounted -> writes silently land on root flash, fill it, fail
#     partway through with confusing "No space left on device" errors.
#  2. USB is vfat/ntfs/exfat -> no Unix permissions on tailscaled.state
#     (which contains the node private key, would be world-readable),
#     no journaling (corrupts on power-cycle), no symlinks (breaks
#     installs that use them).
require_usb_ready() {
    mount | grep -q "on $USB_MOUNT " || \
        die "$USB_MOUNT not mounted; run 'format-usb --yes-wipe' or fix the mount"
    fs=$(usb_fs_type)
    case "$fs" in
        ext4|ext3|ext2|f2fs|btrfs) ;;
        vfat|ntfs|exfat|msdos)
            die "$USB_MOUNT is $fs - needs a POSIX filesystem (run 'format-usb --yes-wipe')" ;;
        *) warn "$USB_MOUNT filesystem is '$fs' - proceeding cautiously" ;;
    esac
}

# === Subcommands ===

# Confirm the environment can host Tailscale before we touch anything.
#
# Why these checks:
# - Architecture: Tailscale ships separate static binaries per arch. We need
#   `mipsle` (little-endian); the Mango's ramips/mt76x8 SoC reports
#   mipsel_24kc to opkg.
# - TUN: Tailscale needs a TUN device for in-kernel mode. Userspace mode
#   exists but cannot act as an exit node, so TUN is mandatory here.
#   NB: /proc/config.gz is NOT present on GL.iNet stock firmware
#   (CONFIG_IKCONFIG_PROC is off), so we check for the module on disk
#   and load it instead of grepping the kernel config.
# - USB device: nothing else works without it, so fail early.
cmd_preflight() {
    log "Preflight checks"

    arch=$(opkg print-architecture 2>/dev/null | awk '/mipsel|mips/ {print $2; exit}')
    [ -n "$arch" ] || die "Could not determine architecture from opkg"
    log "Architecture: $arch"
    case "$arch" in
        mipsel*) ;;
        *) warn "Architecture $arch is not mipsel - Tailscale tarball may not match" ;;
    esac

    # TUN module - find on disk, install if missing, then load
    if ! find /lib/modules -name 'tun*' 2>/dev/null | grep -q .; then
        log "TUN module missing; installing kmod-tun"
        opkg update >/dev/null
        opkg install kmod-tun
    fi
    modprobe tun 2>/dev/null || true
    [ -c /dev/net/tun ] || die "/dev/net/tun missing - TUN unavailable"
    log "TUN: OK"

    # USB device present
    [ -b "$USB_DEV" ] || die "$USB_DEV not present (lsmod | grep usb_storage to debug)"
    log "USB device $USB_DEV present"

    log "Preflight OK"
}

# Wipe and format the USB as ext4, then mount it via UCI fstab.
#
# Why ext4 specifically:
# - vfat has no Unix permissions, so tailscaled.state would be world-
#   readable; the file contains the node private key.
# - vfat has no journaling, so an unclean shutdown (yank the power) can
#   corrupt the state and cost you the auth.
# - ext4 also gives us symlinks, hard links, and sane handling of many
#   small files (Tailscale doesn't write many, but the package extraction
#   does).
#
# Why parted (MBR) rather than sgdisk/gdisk (GPT) or busybox fdisk:
# - The gdisk opkg package on OpenWrt 19.07 ramips ships only interactive
#   `gdisk`, not `sgdisk`, so scripted GPT needs a heredoc into an
#   interactive tool (fragile).
# - GL.iNet stock firmware strips `fdisk` from busybox to save flash, so
#   even busybox fdisk isn't available without an extra package.
# - `parted` has a clean -s (script) mode purpose-built for this, and
#   ships in its own opkg package that's only ~200KB.
# - For a single-partition data USB on a router, MBR works perfectly fine.
#   GPT only matters past 2TB or for >4 primary partitions, neither of
#   which apply here.
#
# This step is destructive and gated behind --yes-wipe.
cmd_format_usb() {
    [ "${1:-}" = "--yes-wipe" ] || \
        die "format-usb destroys all data on $USB_DEV. Re-run with --yes-wipe to confirm."

    log "Formatting $USB_DEV as ext4 (destructive)"

    ensure_pkg parted    parted
    ensure_pkg mkfs.ext4 e2fsprogs
    ensure_pkg blkid     util-linux-blkid
    opkg list-installed 2>/dev/null | grep -q '^kmod-fs-ext4 ' || opkg install kmod-fs-ext4
    opkg list-installed 2>/dev/null | grep -q '^block-mount '  || opkg install block-mount

    # Unmount whatever's there (silently OK if not mounted)
    umount "$USB_MOUNT" 2>/dev/null || true
    umount "$USB_PART"  2>/dev/null || true

    # Wipe any existing partition table (clears both MBR and GPT primary).
    # 34 sectors covers GPT primary header; first sector is enough for MBR.
    dd if=/dev/zero of="$USB_DEV" bs=512 count=34 conv=fsync 2>/dev/null

    # Create one MBR partition spanning the whole device, optimally aligned.
    # -s = script mode (no interactive prompts).
    parted -s "$USB_DEV" mklabel msdos
    parted -s "$USB_DEV" mkpart primary ext4 0% 100%

    # Wait for the partition node to actually appear (kernel re-reads can lag)
    i=0
    while [ ! -b "$USB_PART" ] && [ $i -lt 10 ]; do
        sleep 1
        i=$((i + 1))
    done
    [ -b "$USB_PART" ] || die "Partition $USB_PART did not appear after parted"

    mkfs.ext4 -F -L tsdata "$USB_PART"

    # Wait for blkid to see the new ext4 filesystem. block detect races with
    # filesystem registration on this hardware, so we don't rely on it -
    # instead we read the UUID ourselves and write fstab explicitly.
    i=0
    UUID=""
    while [ -z "$UUID" ] && [ $i -lt 15 ]; do
        sleep 1
        UUID=$(blkid -s UUID -o value "$USB_PART" 2>/dev/null || echo "")
        i=$((i + 1))
    done
    [ -n "$UUID" ] || die "blkid did not report a UUID for $USB_PART after 15s"
    log "Filesystem UUID: $UUID"

    mkdir -p "$USB_MOUNT"

    # Mount immediately for the rest of this run.
    if ! mount | grep -q "on $USB_MOUNT "; then
        mount -t ext4 "$USB_PART" "$USB_MOUNT" || die "Manual mount of $USB_PART failed"
    fi

    # Write fstab explicitly for next boot. We don't use `block detect`
    # because it races with partition registration and can produce empty
    # output; here we know the UUID and target, so just write them.
    cat > /etc/config/fstab <<EOF
config global
    option anon_swap '0'
    option anon_mount '0'
    option auto_swap '0'
    option auto_mount '1'
    option delay_root '5'
    option check_fs '0'

config mount
    option target '$USB_MOUNT'
    option uuid '$UUID'
    option fstype 'ext4'
    option enabled '1'
    option options 'rw,relatime'
EOF

    /etc/init.d/fstab enable
    /etc/init.d/fstab restart

    sleep 1
    fs=$(usb_fs_type)
    [ "$fs" = "ext4" ] || die "USB did not mount as ext4 (got '$fs')"
    log "USB mounted: $(df -h $USB_MOUNT | awk 'NR==2 {print $2 " total, " $4 " free"}')"
}

# Install OpenWrt-side prerequisites and turn on IP forwarding.
#
# - kmod-tun: kernel TUN module (already loaded by preflight, package may
#   need installing on a fresh image).
# - ca-bundle/ca-certificates: needed for Tailscale to validate TLS to the
#   control plane and DERP relays.
# - curl: used to fetch the Tailscale tarball later.
# - iptables + iptables-mod-extra: GL.iNet 19.07 fw3 still uses iptables;
#   the extras provide modules like conntrack that Tailscale relies on.
#
# IP forwarding: we need v4 forwarding (usually already on for a router) and
# v6 forwarding (typically NOT on by default). Without v6, IPv6-capable
# tailnet peers using the Mango as exit node will silently fail for v6 and
# fall back to v4 only.
cmd_install_prereqs() {
    log "Installing prerequisite packages"
    opkg update
    opkg install kmod-tun ca-bundle ca-certificates curl iptables iptables-mod-extra

    # Persist the tun module across reboots
    [ -f /etc/modules.d/30-tun ] || echo tun > /etc/modules.d/30-tun

    # Enable IP forwarding (v4 usually already on, v6 typically not)
    grep -q '^net.ipv4.ip_forward=1'         /etc/sysctl.conf || \
        echo 'net.ipv4.ip_forward=1'         >> /etc/sysctl.conf
    grep -q '^net.ipv6.conf.all.forwarding=1' /etc/sysctl.conf || \
        echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
    sysctl -p >/dev/null

    log "Prereqs installed, IP forwarding enabled"
}

# Download and install the current stable Tailscale build for mipsle.
#
# We fetch the JSON manifest from pkgs.tailscale.com [4] rather than
# hardcoding a version. Two benefits: setup always installs current stable,
# and the same code path works for the `update` subcommand.
#
# Why we DON'T auto-update on every boot:
#  1. Boot-path internet dependency. If home wifi is flaky on boot, the
#     download fails and tailscaled never comes up - and you can't SSH in
#     over the tailnet to fix it because the tailnet isn't up.
#  2. Unreviewed rollout. Tailscale ships regressions occasionally; mipsle
#     is not their most-tested target. You want version changes to be a
#     decision, not an accident.
#  3. State migrations are one-way. Major version bumps can write a newer
#     state DB format that older binaries can't read. Auto-rollback isn't
#     possible; you'd re-auth from scratch.
#
# Use the `update` subcommand manually when you want to roll forward.
cmd_install_tailscale() {
    log "Installing/updating Tailscale"
    require_usb_ready

    mkdir -p "$TS_BASE/state" "$TS_BASE/bin" "$TS_BASE/archive"
    cd "$TS_BASE/archive"

    # Manifest from the official package server [4]. We use sed (not jq) so
    # we don't have to install jq just for one parse - but if you'd rather,
    # `opkg install jq` and replace the sed lines with `jq -r ...`.
    curl -fsSL "https://pkgs.tailscale.com/stable/?mode=json" > pkgs.json
    ts_file=$(sed -n 's/.*"mipsle": "\([^"]*\)".*/\1/p' pkgs.json)
    ts_version=$(sed -n 's/.*"TarballsVersion": "\([^"]*\)".*/\1/p' pkgs.json)
    [ -n "$ts_file" ] && [ -n "$ts_version" ] || die "Could not parse pkgs.tailscale.com manifest"

    current=$(cat "$TS_BASE/installed-version" 2>/dev/null || echo "")
    if [ "$current" = "$ts_version" ] && [ -x "$TS_BASE/bin/tailscaled" ]; then
        log "Already on $ts_version, skipping download"
    else
        log "Installing Tailscale $ts_version ($ts_file)"
        curl -fLO "https://pkgs.tailscale.com/stable/${ts_file}"
        tar -xzf "$ts_file"
        ts_dir="${ts_file%.tgz}"

        # Stop the service before swapping binaries (safe even if not running)
        /etc/init.d/tailscale stop 2>/dev/null || true

        cp "$ts_dir/tailscale"  "$TS_BASE/bin/"
        cp "$ts_dir/tailscaled" "$TS_BASE/bin/"
        chmod +x "$TS_BASE/bin/tailscale" "$TS_BASE/bin/tailscaled"
        echo "$ts_version" > "$TS_BASE/installed-version"
    fi

    # Symlinks live on root flash but cost almost nothing
    ln -sf "$TS_BASE/bin/tailscale"  /usr/sbin/tailscale
    ln -sf "$TS_BASE/bin/tailscaled" /usr/sbin/tailscaled

    log "Tailscale binary: $($TS_BASE/bin/tailscale version | head -1)"
}

# Set up OpenWrt firewall to forward tailnet traffic out to WAN.
#
# Data path when the Mango is acting as exit node:
#   remote peer -> tailscale0 -> (forward) -> wwan/wan -> home router -> internet
#
# Two things must be true:
#  1. Forwarding allowed from a zone containing tailscale0 to the zone
#     containing wwan/wan.
#  2. Masquerade on egress out of wwan/wan. Default on GL.iNet, so free.
#
# Tailscale's Linux install normally adds these rules itself with its own
# iptables chains, but on OpenWrt those rules fight with fw3/fw4 and get
# flushed on firewall reload. The convention is to disable Tailscale's
# netfilter management (--netfilter-mode=off, set in cmd_up) and configure
# equivalent rules declaratively in UCI so they survive reboots and
# firewall restarts. Gad-Elrab [5] explains the underlying problem.
#
# Why a DEDICATED tailscale zone, not "just add tailscale0 to the wan zone":
#  - The wan zone defaults to INPUT=REJECT, blocking inbound Tailscale
#    packets (and incidentally SSH-over-tailnet) at the router itself.
#  - Setting masq=1 on a zone applies to ALL egress out of that zone,
#    including traffic going out tailscale0 toward peers - which breaks
#    source IPs on peer-to-peer connections and MagicDNS.
#  - A dedicated zone keeps the tailnet cleanly separable from upstream
#    in ACLs later.
cmd_configure_firewall() {
    log "Configuring firewall (tailscale zone, forward tailscale -> wan)"

    # Network interface declaration for tailscale0
    if ! uci -q get network.tailscale >/dev/null; then
        uci set network.tailscale=interface
        uci set network.tailscale.ifname='tailscale0'
        uci set network.tailscale.proto='none'
        uci set network.tailscale.auto='1'
        uci commit network
    fi

    # Dedicated firewall zone
    # input=ACCEPT       -> SSH-over-tailnet works, tailnet peers can ping
    #                       services on the Mango itself
    # output=ACCEPT      -> Mango can initiate connections out the tailnet
    # forward=REJECT     -> default-deny for cross-zone forwarding from
    #                       tailscale; we add an explicit allow rule below
    # masq=0             -> do NOT masquerade out tailscale0 (we only want
    #                       masq on egress to wan)
    # mtu_fix=1          -> clamp MSS to PMTU; helps with overlay quirks
    if ! uci show firewall | grep -q "name='tailscale'"; then
        zone=$(uci add firewall zone)
        uci set "firewall.$zone.name=tailscale"
        uci set "firewall.$zone.input=ACCEPT"
        uci set "firewall.$zone.output=ACCEPT"
        uci set "firewall.$zone.forward=REJECT"
        uci set "firewall.$zone.masq=0"
        uci set "firewall.$zone.mtu_fix=1"
        uci add_list "firewall.$zone.network=tailscale"
    fi

    # Forwarding tailscale -> wan (covers both eth-WAN and wwan in repeater
    # mode; both are members of the wan zone on GL.iNet firmware)
    if ! uci show firewall | grep -B1 "dest='wan'" | grep -q "src='tailscale'"; then
        fwd=$(uci add firewall forwarding)
        uci set "firewall.$fwd.src=tailscale"
        uci set "firewall.$fwd.dest=wan"
    fi

    uci commit firewall
    /etc/init.d/network reload
    /etc/init.d/firewall restart
    log "Firewall configured"
}

# Install a procd init script for tailscaled.
#
# procd is OpenWrt's service supervisor, the equivalent of systemd or runit
# for this environment. The respawn parameter restarts tailscaled if it
# dies. Logs go to procd's logread (use `logread -e tailscaled` to inspect).
#
# We log to procd stdout/stderr rather than /dev/null. Pat Regan's writeup
# [7] specifically warns about the trap of redirecting tailscaled output
# to /dev/null and then having no way to debug when something breaks - and
# the Mango's logs are ephemeral on top of that.
cmd_install_init() {
    log "Installing /etc/init.d/tailscale"

    cat > /etc/init.d/tailscale <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10

PROG=/mnt/sda1/opt/tailscale/bin/tailscaled
STATE_DIR=/mnt/sda1/opt/tailscale/state
SOCKET=/var/run/tailscale/tailscaled.sock

start_service() {
    mkdir -p "$STATE_DIR" /var/run/tailscale
    procd_open_instance
    procd_set_param command "$PROG" \
        --state="$STATE_DIR/tailscaled.state" \
        --socket="$SOCKET" \
        --port=41641 \
        --tun=tailscale0
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
    chmod +x /etc/init.d/tailscale
    /etc/init.d/tailscale enable
    /etc/init.d/tailscale restart
    sleep 3

    pgrep tailscaled >/dev/null || die "tailscaled failed to start; check 'logread -e tailscaled'"
    log "tailscaled running (pid $(pgrep tailscaled))"
}

# Add an SSH public key to dropbear's authorized_keys, so the Mango becomes
# reachable over SSH from any tailnet peer (the firewall zone's input=ACCEPT
# already opened port 22 over tailscale0).
#
# Why we don't disable password auth here: if the key is wrong (typo, wrong
# format, etc) and we kill passwords in the same step, you're locked out.
# Test SSH first via tailnet, then run `disable-password-ssh` once it works.
#
# Why dropbear instead of Tailscale SSH: for a single-person home exit node,
# dropbear + keys is simpler and more robust than Tailscale SSH on a static-
# binary install. Tailscale SSH needs ACL configuration in the admin console
# and has historically been flaky on OpenWrt static installs. If you're
# already using Tailscale SSH elsewhere in your tailnet for identity
# consistency, add `--ssh` to cmd_up's tailscale up flags instead.
cmd_configure_ssh() {
    ssh_key=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --ssh-key=*)      ssh_key="${1#--ssh-key=}" ;;
            --ssh-key-file=*) ssh_key=$(cat "${1#--ssh-key-file=}") ;;
            *) die "Unknown option: $1 (use --ssh-key=... or --ssh-key-file=...)" ;;
        esac
        shift
    done
    [ -n "$ssh_key" ] || die "Provide --ssh-key='ssh-ed25519 ...' or --ssh-key-file=path/to/key.pub"

    log "Adding SSH key to /etc/dropbear/authorized_keys"
    mkdir -p /etc/dropbear
    chmod 700 /etc/dropbear
    touch /etc/dropbear/authorized_keys

    if grep -qF "$ssh_key" /etc/dropbear/authorized_keys; then
        log "Key already present, no change"
    else
        echo "$ssh_key" >> /etc/dropbear/authorized_keys
        log "Key added"
    fi
    chmod 600 /etc/dropbear/authorized_keys

    log "Test SSH from a tailnet peer BEFORE disabling password auth:"
    log "    ssh root@$TS_HOSTNAME"
    log "When that works, run: $0 disable-password-ssh"
}

# Lock dropbear down to public-key auth only.
#
# Refuses to run if authorized_keys is empty - this would otherwise be a
# foot-cannon: disable passwords with no keys installed and you cannot SSH
# in by any means.
cmd_disable_password_ssh() {
    [ -s /etc/dropbear/authorized_keys ] || \
        die "No authorized_keys present - refusing to lock you out"

    log "Disabling password auth on dropbear"
    uci set dropbear.@dropbear[0].PasswordAuth='off'
    uci set dropbear.@dropbear[0].RootPasswordAuth='off'
    uci commit dropbear
    /etc/init.d/dropbear restart
    log "Password SSH disabled (key auth only now)"
}

# Authenticate the Mango to the tailnet and advertise it as an exit node.
#
# Flag rationale:
#  --advertise-exit-node : the whole point. Approve in admin console after.
#  --accept-dns=false    : let dnsmasq on the Mango keep owning DNS;
#                          avoids tailscaled fighting /etc/resolv.conf.
#                          (Set to =true if you want MagicDNS on clients
#                          using this exit node.)
#  --hostname            : readable name in the admin console.
#  --netfilter-mode=off  : we configured firewall declaratively in UCI;
#                          do NOT let tailscaled add its own iptables rules
#                          (they get flushed on /etc/init.d/firewall restart
#                          and fight with fw3 anyway).
#
# Procedure based on the GL.iNet forum exit-node SSH writeup [6].
cmd_up() {
    log "Bringing Tailscale up - visit the URL it prints to authorize"
    tailscale up \
        --advertise-exit-node \
        --accept-dns=false \
        --hostname="$TS_HOSTNAME" \
        --netfilter-mode=off
    log "Now go to https://login.tailscale.com/admin/machines and:"
    log "  1. Find '$TS_HOSTNAME'"
    log "  2. Edit route settings - enable as exit node"
    log "  3. Optionally disable key expiry"
}

# Preserve config across firmware upgrades.
#
# OpenWrt sysupgrade resets /etc by default but reads /etc/sysupgrade.conf
# for additional paths to preserve. Files under /etc/config (UCI) are
# already preserved automatically; what we add here is the extra stuff that
# lives outside /etc/config:
#
# - /etc/init.d/tailscale          : custom procd script
# - /etc/modules.d/30-tun          : auto-load tun module on boot
# - /etc/dropbear/authorized_keys  : SSH public keys (NOT in /etc/config)
#
# Note that /mnt/sda1/* is on USB and unaffected by sysupgrade entirely.
cmd_persist_upgrade_config() {
    log "Adding paths to /etc/sysupgrade.conf"
    [ -f /etc/sysupgrade.conf ] || touch /etc/sysupgrade.conf
    for path in /etc/init.d/tailscale /etc/modules.d/30-tun /etc/dropbear/authorized_keys; do
        if grep -qxF "$path" /etc/sysupgrade.conf; then
            log "  $path (already present)"
        else
            echo "$path" >> /etc/sysupgrade.conf
            log "  $path (added)"
        fi
    done
}

# Print a snapshot of everything relevant to debugging.
cmd_status() {
    echo "=== Architecture / firmware ==="
    cat /etc/openwrt_release 2>/dev/null | grep -E 'DISTRIB_(ID|RELEASE|TARGET|ARCH)'
    echo
    echo "=== USB mount ==="
    if mount | grep -q "on $USB_MOUNT "; then
        mount | grep "on $USB_MOUNT "
        df -h "$USB_MOUNT" | tail -n +1
    else
        echo "(not mounted)"
    fi
    echo
    echo "=== Tailscale binary ==="
    if [ -x "$TS_BASE/bin/tailscaled" ]; then
        "$TS_BASE/bin/tailscale" version 2>/dev/null | head -3
    else
        echo "(not installed at $TS_BASE/bin/)"
    fi
    echo
    echo "=== tailscaled service ==="
    if pgrep tailscaled >/dev/null; then
        echo "running (pid $(pgrep tailscaled))"
    else
        echo "not running"
    fi
    echo
    echo "=== Tailnet status ==="
    tailscale status 2>/dev/null || echo "(not authenticated or daemon down)"
    echo
    echo "=== Firewall (tailscale zone & forwarding) ==="
    uci show firewall 2>/dev/null | grep -E "tailscale" || echo "(no tailscale zone configured)"
}

# Pull the current stable Tailscale and restart the service.
# See cmd_install_tailscale for why this is manual rather than cron-driven.
cmd_update() {
    log "Updating Tailscale to current stable"
    cmd_install_tailscale
    /etc/init.d/tailscale restart
    sleep 3
    tailscale version | head -1
}

# Run every stage in order. Requires both --yes-wipe (because format-usb is
# destructive) and SSH_PUBKEY env var (so we can install your key).
cmd_all() {
    [ "${1:-}" = "--yes-wipe" ] || \
        die "'all' will format $USB_DEV. Re-run with --yes-wipe to confirm."
    [ -n "${SSH_PUBKEY:-}" ] || \
        die "Set SSH_PUBKEY env var to your ssh public key string before running 'all'"

    cmd_preflight
    cmd_format_usb --yes-wipe
    cmd_install_prereqs
    cmd_install_tailscale
    cmd_configure_firewall
    cmd_install_init
    cmd_configure_ssh "--ssh-key=$SSH_PUBKEY"
    cmd_persist_upgrade_config

    echo
    log "Setup complete. Next:"
    log "  1. $0 up"
    log "  2. Approve as exit node in admin console"
    log "  3. Test SSH from a peer: ssh root@$TS_HOSTNAME"
    log "  4. When SSH works: $0 disable-password-ssh"
}

usage() {
    cat <<EOF
Usage: $0 <command> [args]

Set up a GL-MT300N-V2 (Mango) as a Tailscale exit node, with Tailscale
binaries and state on a USB drive. Assumes the Mango is in wifi repeater
mode against your home wifi. See the comments at the top of the script
for background and references.

Stages (each idempotent, can be re-run):
  preflight                  Check arch, TUN module, USB device present
  format-usb --yes-wipe      Wipe USB and format ext4 (DESTRUCTIVE)
  install-prereqs            opkg deps + enable IP forwarding
  install-tailscale          Download current stable mipsle Tailscale
  configure-firewall         Tailscale UCI iface + zone + forward to wan
  install-init               /etc/init.d/tailscale, enable, start
  configure-ssh              --ssh-key='ssh-ed25519 AAAA... user'
                          OR --ssh-key-file=/path/to/key.pub
  disable-password-ssh       Lock dropbear to key auth (do AFTER testing keys)
  up                         tailscale up --advertise-exit-node ...
  persist-upgrade-config     Add config paths to /etc/sysupgrade.conf

Convenience:
  all --yes-wipe             Run preflight..persist-upgrade-config in order.
                             Requires SSH_PUBKEY env var.
  update                     Pull current stable Tailscale, restart service
  status                     Show install / mount / service / tailnet status
  help                       This message

Env overrides:
  USB_DEV     ($USB_DEV)
  USB_PART    ($USB_PART)
  USB_MOUNT   ($USB_MOUNT)
  TS_HOSTNAME ($TS_HOSTNAME)
  SSH_PUBKEY  (required for 'all')

Example end-to-end:
  export SSH_PUBKEY="ssh-ed25519 AAAA... me@laptop"
  $0 all --yes-wipe
  $0 up
  # ... approve exit node in admin console, test SSH from a peer ...
  $0 disable-password-ssh
EOF
}

cmd="${1:-}"
[ -n "$cmd" ] || { usage; exit 1; }
shift || true

case "$cmd" in
    preflight)              cmd_preflight ;;
    format-usb)             cmd_format_usb "$@" ;;
    install-prereqs)        cmd_install_prereqs ;;
    install-tailscale)      cmd_install_tailscale ;;
    configure-firewall)     cmd_configure_firewall ;;
    install-init)           cmd_install_init ;;
    configure-ssh)          cmd_configure_ssh "$@" ;;
    disable-password-ssh)   cmd_disable_password_ssh ;;
    up)                     cmd_up ;;
    persist-upgrade-config) cmd_persist_upgrade_config ;;
    status)                 cmd_status ;;
    update)                 cmd_update ;;
    all)                    cmd_all "$@" ;;
    help|-h|--help)         usage ;;
    *) die "Unknown command: $cmd (run '$0 help')" ;;
esac
