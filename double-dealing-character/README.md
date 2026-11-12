# double-dealing-character

GL.iNet GL-MT2500 (Brume 2) running GL.iNet firmware, set up as a
Tailscale exit node. Only WAN is plugged in, into the home switch;
manage it over the tailnet. The hostname previously belonged to a Mango,
whose setup lives in
[`mango/`](mango/README.md).

This was set up by hand with Claude's help, not from a script. The steps
below are what worked.

## Set up from scratch

The Brume's admin UI is on its LAN side at 192.168.8.1, so bootstrapping
needs both ports on the home switch for a while: WAN for internet, LAN
for access.

1. Plug WAN and LAN into the switch.
2. Alias the Mac onto the Brume's subnet. Use the `netmask` keyword;
   without it, macOS reads the mask as a broadcast address.

   ```sh
   sudo ifconfig en0 alias 192.168.8.2 netmask 255.255.255.0
   ```

3. Open `http://192.168.8.1` and disable the LAN DHCP server before
   anything else, so it stops fighting the home router for leases. If
   the browser can't load the page but `curl` can, grant the browser
   access in System Settings → Privacy & Security → Local Network.
4. SSH in as root and sync the clock. A fresh Brume came up 16 months
   behind with NTP never run, which breaks TLS to Tailscale's control
   plane.

   ```sh
   /etc/init.d/sysntpd restart
   date
   ```

5. Enable Tailscale. Toggling it in the UI didn't save `enabled`, so the
   init script exited without starting `tailscaled`, and the UI failed
   to get a bind link.

   ```sh
   uci set tailscale.settings.enabled='1'
   uci commit tailscale
   /etc/init.d/tailscale start
   tailscale up --advertise-exit-node
   ```

6. Open the login URL that `tailscale up` prints. In the
   [Tailscale console](https://login.tailscale.com/admin/machines),
   approve the exit node, disable key expiry, and rename the machine to
   `double-dealing-character`.
7. Reboot and confirm `tailscale status` still shows it offering an exit
   node.
8. Unplug LAN and drop the alias with
   `sudo ifconfig en0 -alias 192.168.8.2`.

To test the exit node, select it from a peer off the home network, such
as a phone on cellular, and check that its public IP becomes the home
IP. A peer on the home network gets the same IP either way.

If replies stop coming back, for example after a firmware upgrade,
suspect mwan3. It hijacked the Mango's exit-node return path; see
[the Mango note](../docs/double-dealing-character/mango/2026-08-07-exit-node-return-path.md).
