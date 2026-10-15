# double-dealing-character

GL.iNet GL-MT300N-V2 (Mango) running GL.iNet firmware on OpenWrt 22.03.4, set
up as a Tailscale exit node. Tailscale binaries and state live on a USB drive
because internal flash is too small to hold them.

Almost all of this is vibed — `mango-tailscale-setup.sh` and the notes below
were written by Claude and never hand-audited. Read before running.

`mango-tailscale-setup.sh` does the whole install. Copy it to the router and
run it there; see the comments at the top of the script for background and
references, and `mango-tailscale-setup.sh help` for the subcommands.

```sh
scp double-dealing-character/mango/mango-tailscale-setup.sh root@192.168.8.1:/tmp/

export SSH_PUBKEY="ssh-ed25519 AAAA... me@laptop"
/tmp/mango-tailscale-setup.sh all --yes-wipe
/tmp/mango-tailscale-setup.sh up
```

- Approve as an exit node and disable key expiry in the [Tailscale console](https://login.tailscale.com/admin/machines)
- Test SSH from a tailnet peer, then `/tmp/mango-tailscale-setup.sh disable-password-ssh`

Test that step with `ssh -o PasswordAuthentication=no root@double-dealing-character
true`, not a plain `ssh`. A plain `ssh` succeeds on either method, so a stale key
plus a silent fallback to password auth looks identical to working key auth. The
`disable-password-ssh` guard only checks that `authorized_keys` is non-empty,
which a stale key satisfies, and disabling passwords in that state locks you out
of a box whose only other door is its own LAN at 192.168.8.1.

`all` runs `configure-routing` as one of its stages, which is what keeps
exit-node replies inside the tunnel rather than sending them back out the WAN.
Run it on its own if the exit node stops working after a firmware upgrade.

`mango-tailscale-setup.sh status` prints install, mount, service, tailnet, and
exit-node return path state in one go.

## Notes

- [2026-08-07: exit node return path hijacked by mwan3](../../docs/double-dealing-character/mango/2026-08-07-exit-node-return-path.md)
