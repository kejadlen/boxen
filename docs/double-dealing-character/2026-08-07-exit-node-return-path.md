# Exit node return path hijacked by mwan3

Fixed on 2026-08-10 by adding `100.64.0.0/10 dev tailscale0` to the `main`
table; the two sections on removing mwan3 record approaches that failed and
should not be retried. Verified end to end — a peer's egress IP became the
Mango's public address.

Symptom: a peer (the Apple TV) selects `double-dealing-character` as its exit
node and gets no internet. SSH into the Mango works, and `curl https://google.com/`
from the Mango works, so the box itself is fine.

Cause: GL.iNet firmware runs [mwan3][mwan3] for WAN failover, and mwan3
installs an `ip rule` at priority 1001 that captures everything arriving on the
WAN interface:

```
1001:	from all iif eth0.2 lookup 1
```

Table 1 holds a default route but none of the tailnet routes. Those live only
in table 52, which Tailscale reaches through its own rule at priority 5270.
Rule 1001 wins, so any packet arriving on the WAN destined for a tailnet
address goes back out to the upstream router instead of into `tailscale0`:

```sh
ip route get 100.86.9.54 from 8.8.8.8 iif eth0.2
# 100.86.9.54 from 8.8.8.8 via 192.168.1.1 dev eth0.2 table 1
#     cache <redirect> iif eth0.2
```

Only the return path breaks. The forward path is fine — the fw4 zone, the
`tailscale` → `wan` forwarding rule, and masquerade on `eth0.2` all work, and
`ip route get 8.8.8.8 from 100.86.9.54 iif tailscale0` resolves correctly.
Replies come back on `eth0.2`, get de-NAT'd to the peer's `100.x` address in
prerouting, then hit rule 1001.

This is also why the box looks healthy. Traffic addressed to the Mango itself
matches the `local` table at priority 0 and never reaches rule 1001, so `curl`
and SSH-over-tailnet are unaffected. Forwarded traffic to a tailnet address is
the only case that breaks, and the exit node is the only thing that generates
it.

[mwan3]: https://openwrt.org/docs/guide-user/network/wan/multiwan/mwan3

## Do not "fix" this by hoisting table 52

The obvious patch is to move the table 52 lookup above mwan3's rule:

```sh
# DO NOT DO THIS
ip rule add to 100.64.0.0/10 lookup 52 pref 1000
```

It works — verified end to end, with a peer's egress IP changing to the
Mango's — and then the Mango dropped off the tailnet a few minutes later. The
control plane still reported it online, but WireGuard handshakes stopped and it
needed a power cycle. The rule was never persisted, so the power cycle is
enough to undo it.

The causal link was never confirmed, because the box became unreachable before
it could be inspected. What is certain is that the rule is mis-shaped.
Tailscale deliberately places `fwmark 0x80000 → main / default / unreachable`
at priorities 5210-5250, *above* its table 52 rule at 5270, so that tailscaled's
own encrypted packets can never re-enter the tunnel. A bare table 52 lookup at
priority 1000 sits above that guard and breaks the invariant. Any rule added
above 5210 has to carry the same fwmark exclusion.

## Stopping mwan3 wedges the box too

The obvious next move is to remove mwan3 outright. Nothing on this box needs
it: `mwan3 status` reports `wan` (wired, `eth0.2`, 192.168.1.26) online and
`wwan`, `tethering`, and all three v6 interfaces offline, so GL.iNet's failover
between ethernet, repeater, and tethering has nothing to fail over to. Removing
it drops rules 1001, 2001, 2061, and 2062, and lets Tailscale's 5210-5270 set
work as designed.

```sh
# DO NOT DO THIS OVER THE TAILNET
/etc/init.d/mwan3 stop && /etc/init.d/mwan3 disable
```

Tried on 2026-08-08. The SSH session died the instant the command ran, which on
its own is expected — `mwan3 stop` flushes conntrack, and the session was
established through it. The box never came back.

The failure signature differs from the table-52 attempt. WireGuard stayed up:
`tailscale status` kept reporting the node active with `tx` and `rx` both
climbing by disco-sized increments, though the direct connection degraded to
the `nyc` relay within a minute. Nothing over the tunnel worked — no ping, no
SSH to `100.110.110.52`. Handshakes fine, tun path dead. The earlier attempt
lost handshakes instead.

What the two attempts share is the trigger, not the symptom. Both mutated the
`ip rule` table underneath a running tailscaled, and both ended in a power
cycle with no mechanism confirmed, because the box became unreachable before it
could be inspected. Suspect tailscaled reacting badly to its routing
environment changing beneath it, rather than anything specific to the rule that
changed.

## `mwan3 disable` does not disable mwan3

The reboot that followed brought mwan3 straight back. `/etc/init.d/mwan3
enabled` reports disabled and `/etc/rc.d` holds no symlink, yet `mwan3rtmon`
and `mwan3track` are running and rule 1001 is present.

`/etc/hotplug.d/iface/15-mwan3` starts it. The WAN's DHCP `ifup` on boot fires
the hotplug event, the event starts mwan3, and the rc.d symlink `disable`
removed never enters into it. Three more scripts in that directory reference
mwan3 as well (`16-mwan3`, `16-mwan3-user`, `17-dual-sim`).

So the whole "remove mwan3" line of attack is a dead end on GL.iNet firmware
short of deleting the hotplug scripts, which a firmware upgrade would restore.
Leave mwan3 running and work with it.

## The fix

Put the tailnet aggregate in the `main` table and let mwan3 copy it down:

```sh
ip route add 100.64.0.0/10 dev tailscale0
```

The `mwan3rtmon` daemon continuously mirrors `main` into every interface table.
It diffs the two and reconciles in both directions, adding routes main has and
deleting routes main lacks (the `ipv4.main` loop in `/lib/mwan3/mwan3.sh`).
That has two consequences. A route added straight to table 1 is reaped on the
next sync, so the hotplug script this note previously recommended for it would
have been racing a monitor loop. A route added to `main` lands in table 1
within seconds and stays there across mwan3's rebuilds, for free.

Table 52 holds a per-peer `/32` for every node rather than an aggregate, so
there is no single tailscale-managed route to mirror; the `/10` covers the
tailnet in one entry.

This does not repeat the mistake the table-52 hoist made. Rules 5210-5250 exist
to keep tailscaled's own encrypted packets out of the tunnel, and those packets
are addressed to peers' public endpoints, never into `100.64.0.0/10`. A route
for that prefix in `main` cannot catch them.

Persist it from a hotplug script keyed on the tailscale interface, since the
route needs `tailscale0` to exist and tailscaled starts last at `START=99`:

```sh
# /etc/hotplug.d/iface/30-tailnet-route
[ "$INTERFACE" = "tailscale" ] || exit 0
case "$ACTION" in
	ifup)   ip route replace 100.64.0.0/10 dev tailscale0 ;;
	ifdown) ip route del 100.64.0.0/10 dev tailscale0 2>/dev/null ;;
esac
```

`INTERFACE` is the UCI section name, `tailscale`, not the device name. To
confirm the event fires for it without disturbing anything, look for
`network.tailscale.up='1'` in `/var/state/network` — `00-netstate` writes that
line from the same hotplug event.

Note that `ifup tailscale` is not a test of this. netifd no-ops `ifup` on an
interface that is already up, so no event fires and the script never runs.

Installed by `mango-tailscale-setup.sh configure-routing`, and listed in
`/etc/sysupgrade.conf` so it survives a firmware upgrade.

## Applying changes without losing the box

Two of the three attempts here wedged the Mango and cost a power cycle, both
while mutating routing state under a running tailscaled. Arm a dead-man's
switch before the change and the failure mode costs ten minutes instead of a
trip to the hardware:

```sh
nohup sh -c 'sleep 600; ip route del 100.64.0.0/10 dev tailscale0' >/dev/null 2>&1 &
ip route add 100.64.0.0/10 dev tailscale0
```

Verify, then `kill` the pending `sleep` once the change proves good.

Adding a route turned out to be far safer than the earlier attempts, which
deleted or reordered `ip rule` entries and flushed conntrack. Nothing dropped,
including the SSH session.

## Recovering a wedged box

Power-cycle it. Nothing tried here survives a reboot — including `mwan3
disable`, for the reasons above.

A box that comes back still broken is by definition not reachable over the
tailnet. Reach it on its own LAN or wifi at 192.168.8.1. Its WAN-side address
on the home LAN (192.168.1.26) is not a second way in; the `wan` zone defaults
to `input=REJECT` on GL.iNet firmware, and this has not been tested from a host
on that subnet.

## Verifying

From the Mango, check that a reply destined for a peer routes into the tunnel
rather than back out the WAN. With the fix in place the answer comes from table
1, not table 52 — mwan3's rule 1001 still wins, it just now resolves correctly:

```sh
ip route get 100.86.9.54 from 8.8.8.8 iif eth0.2
# want:   100.86.9.54 from 8.8.8.8 dev tailscale0 table 1
# broken: 100.86.9.54 from 8.8.8.8 via 192.168.1.1 dev eth0.2 table 1
```

From a peer, confirm the egress IP actually changes:

```sh
curl -s https://ifconfig.me; echo
tailscale set --exit-node=double-dealing-character
curl -s https://ifconfig.me; echo   # should be the Mango's public IP
tailscale set --exit-node=
```

## Still open: IPv6 blackholes

The node advertises `::/0` but has no IPv6 upstream at all — `ip -6 route`
shows only link-local, netcheck reports `ipv6=false`, and `srcnat_wan`
masquerades IPv4 only. Every IPv6 connection through this exit node dies and
depends on Happy Eyeballs falling back to IPv4, which shows up as sluggishness
rather than outright failure. Unrelated to the mwan3 problem.
