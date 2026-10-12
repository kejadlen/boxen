# legacy-of-lunatic-kingdom

My NAS, running on a Beelink ME mini.

As of 2025Q4, it's running 3 2TB NVMe drives in a RAID5 configuration.

## bootstrapping

- Assumes the base OS has been installed and the system is accessible via SSH.

### Adding SSH keys

```sh
# To log in and add keys manually, PubkeyAuthentication needs to be disabled
# since otherwise we'll run out of authentication attempts from trying SSH keys.
ssh -o PubkeyAuthentication=no 192.168.1.xyz

# Alternatively, ssh-copy-id can be used, but it'll put a bunch of other keys
# into .ssh/authorized_keys that should be cleaned up. Also SSH_AUTH_SOCK is
# needed since it uses ssh-add to get the public keys.
SSH_AUTH_SOCK=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock ssh-copy-id 192.168.1.xyz
```

### Ansible

This needs to be done until we have Tailscale up and running, since otherwise
we can't get the IP for the hostname.

```sh
# Using ssh_config
Host legacy-of-lunatic-kingdom
  Hostname 192.168.1.xyz

# Using hosts.yml
all:
  hosts:
    legacy-of-lunatic-kingdom:
      ansible_host: 192.168.1.xyz
```

Now Ansible can be run, needing `--ask-become-pass` since `/etc/sudoers` needs
to be updated:

```sh
ansible-playbook --ask-become-pass --limit=legacy-of-lunatic-kingdom legacy-of-lunatic-kingdom/main.yml
```

Tailscale should be installed now, so SSH in and log into Tailscale:

```sh
ssh 192.168.1.xyz

sudo tailscale login
```

Disable key expiry in Tailscale.

And now the IP override can be removed since we should get DNS resolution
through Tailscale.

## TODO

- jellyfin
- immich
