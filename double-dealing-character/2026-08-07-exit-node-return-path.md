# Exit node return path hijacked by mwan3

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

## Fixing it

Preferred: stop mwan3. This is a single-WAN box, and mwan3 only exists for
GL.iNet's failover between ethernet, repeater, and tethering. Removing it drops
rules 1001, 2001, 2061, and 2062, and lets Tailscale's 5210-5270 set work as
designed.

```sh
/etc/init.d/mwan3 stop && /etc/init.d/mwan3 disable
```

If failover is worth keeping, add the tailnet prefix to mwan3's table instead
of reordering rules. This leaves tailscaled's own traffic path untouched,
because locally generated packets have `iif lo` and never match rule 1001:

```sh
ip route add 100.64.0.0/10 dev tailscale0 table 1
```

mwan3 flushes table 1 on WAN events, so this needs re-adding from a hotplug
script to survive.

Neither fix is in `mango-tailscale-setup.sh` yet.

## Verifying

From the Mango, check that a reply destined for a peer routes into the tunnel
rather than back out the WAN:

```sh
ip route get 100.86.9.54 from 8.8.8.8 iif eth0.2
# want: 100.86.9.54 from 8.8.8.8 dev tailscale0 table 52
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
