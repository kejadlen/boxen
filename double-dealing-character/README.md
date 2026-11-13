# double-dealing-character

GL.iNet GL-MT2500 (Brume 2) running GL.iNet firmware, set up as a
Tailscale exit node. Only WAN is plugged in, into the home switch;
manage it over the tailnet. The hostname previously belonged to a Mango,
whose setup lives in
[`mango/`](mango/README.md).

[`setup.sh`](setup.sh) does the on-box setup and is safe to rerun. It
runs on the Brume over SSH, so nothing needs copying over:

```sh
ssh root@double-dealing-character sh -s < double-dealing-character/setup.sh
```

The script does the following:

- Syncs the clock if it's behind the firmware build date. A fresh Brume
  came up 16 months behind with NTP never run, which breaks TLS to
  Tailscale's control plane.
- Enables Tailscale in UCI and starts `tailscaled`. Toggling Tailscale
  in the UI didn't save `enabled`, so the init script exited without
  starting it.
- Patches GL's `/usr/bin/gl_tailscale` to pass `--advertise-exit-node`.
  Interface hotplug scripts in `/etc/hotplug.d/iface/` and
  `/etc/hotplug.d/net/` call its `restart` action, which ends with
  `tailscale up --reset`. That resets every flag it doesn't pass, so
  unpatched, a network event silently withdraws the exit node.
- Advertises the exit node, logging in first on a fresh box, and fails
  unless `AdvertiseRoutes` includes `0.0.0.0/0`.

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
4. Run the setup script over the LAN. It prints a login URL and waits.

   ```sh
   ssh root@192.168.8.1 sh -s < double-dealing-character/setup.sh
   ```

5. Open the login URL. In the
   [Tailscale console](https://login.tailscale.com/admin/machines),
   approve the exit node, disable key expiry, and rename the machine to
   `double-dealing-character`.
6. On the Brume, run `gl_tailscale restart`, then reboot. After each,
   confirm `tailscale status` still shows it offering an exit node.
7. Unplug LAN and drop the alias with
   `sudo ifconfig en0 -alias 192.168.8.2`.

To test the exit node, select it from a peer off the home network, such
as a phone on cellular, and check that its public IP becomes the home
IP. A peer on the home network gets the same IP either way.

## Troubleshoot

If peers stop seeing it as an exit node, rerun `setup.sh`. A firmware
upgrade restores the stock `gl_tailscale`, which drops the exit node on
the next network event.

If replies stop coming back, for example after a firmware upgrade,
suspect mwan3. It hijacked the Mango's exit-node return path; see
[the Mango note](../docs/double-dealing-character/mango/2026-08-07-exit-node-return-path.md).
