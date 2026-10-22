# Deploy tooling for imperishable-night

The [migration plan](2026-10-16-migrating-from-lotus-land-story.md)
assumes NixOS manages imperishable-night. This document compares NixOS
with the alternatives worth considering. No choice is final yet.

## Constraints

Any option has to work within the following constraints:

- It manages one host whose services all run as podman containers. The
  goal is Quadlet units in `/etc/containers/systemd/`, as in the
  [podman migration](../lotus-land-story/2026-09-04-podman-migration.md).
- The workstation is a Mac without Nix installed.
- Secrets are in sops, in `host_vars/*.sops.yml`.
- A human runs every deploy.
- The root tofu configuration provisions the instance on Linode.
- The rest of the fleet stays on Ansible.

## Two models

The options split into two models, and the split matters more than any
single tool.

Convergent tools check each piece of the system against a description
and fix what differs. Ansible works this way. Anything the description
doesn't mention, such as a package installed by hand or a file left
behind by a removed service, stays on the host. Rolling back means
applying the old description and hoping it converges to the old state.

Image-based tools build the whole system as one artifact and switch to
it. NixOS, bootc, and Fedora CoreOS work this way. What the description
doesn't mention doesn't exist, and rolling back means booting the
previous artifact.

## Options

The following table summarizes the options. The sections after it
cover each one.

| Option | Model | Workstation needs | Rollback |
|---|---|---|---|
| NixOS | Image-based | Nothing, or Nix | Previous generation |
| bootc | Image-based | podman | Previous image |
| Fedora CoreOS or Flatcar | Image-based, configured at first boot | butane | Reprovision |
| frork | Convergent | frork | Re-run the previous bundle |
| pyinfra | Convergent | Python | Re-run the previous code |

### NixOS

The migration plan covers how NixOS would work, including two ways to
deploy without Nix on the workstation. NixOS has the most complete
answer here: whole-system rollback, sops-nix for secrets, and
`virtualisation.oci-containers` for podman containers.

The cost is learning Nix, plus a configuration language unlike anything
else in this repository. nixos-anywhere and nixos-rebuild both need Nix
on the machine that runs them.

### bootc

bootc builds the operating system from a Containerfile. The host runs
`bootc switch` or `bootc upgrade` to move to a new image, and keeps the
previous one for rollback. Quadlet units go into the image like any
other file.

bootc gives NixOS's rollback model in a format this repository already
uses. The Mac can build the images with podman. The costs are a
container registry to push the images to, and a project that is younger
than the alternatives, with Fedora- and CentOS-based images rather than
Debian. Whether a bootc image boots on Linode, and how to install one
there, is unverified.

### Fedora CoreOS or Flatcar

These are immutable, container-focused operating systems. A Butane file
compiles to an Ignition config, which tofu passes to the instance at
creation. Quadlets are the native way to run services on Fedora CoreOS.

This option needs the least tooling: tofu and one config file. Ignition
runs only at first boot, though, so changing anything means
reprovisioning the instance or adding a second tool. Tofu makes
reprovisioning cheap, but every service's data has to live on a volume
that survives it. Whether either OS has a ready-made Linode image is
unverified.

### frork

[frork](https://github.com/kejadlen/frork) is a convergent tool written
in Fennel, inspired by bork. It runs `status` to check assertions and
`satisfy` to fix them. It embeds Lua 5.4 through mlua's `vendored`
feature, so a static `x86_64-unknown-linux-musl` build would need no
runtime dependencies on the host.

frork could deploy a single per-host binary. CI cross-compiles a
generic Linux frork once. A `frork bundle` command copies that binary
and appends the compiled host scripts plus a trailer, the way
`deno compile` does. At startup, frork finds the trailer and runs the
embedded scripts. Bundling compiles nothing, so the Mac produces a
Linux artifact without a cross toolchain. Deploying means copying the
binary, running `status` as a dry run, and then running `satisfy`.

Quadlets keep the host's needs small, since most services become a file
and a restart. frork currently supports `symlink`, `directory`, `git`,
`brew`, and `brew-bundle`, and releases only for macOS. Managing this
host would need the following additions:

- A Linux release
- File assertions with content, mode, and owner
- `systemd` assertions that reload units and enable and start them
- `apt` assertions for host packages
- Change notification, so that a unit restarts only when its file
  changed
- A `status` diff that shows what would change in a file
- Secrets decrypted on the host with `sops -d`, never baked into the
  bundle

frork pairs with Debian trixie, not NixOS. The cost is maintaining a
deploy tool for a host that runs the tailnet's login provider and family
data, with no outside modules to draw on.

### pyinfra

pyinfra is a convergent tool, like Ansible. It pushes changes over SSH
and is written as Python instead of YAML. It is the smallest change
from Ansible and runs faster, but it keeps Ansible's drift and rollback
behavior.

## Not considered

The following options don't fit the constraints:

- Salt, Puppet, and Chef are convergent like Ansible, with more setup.
- k3s with Flux, or Nomad, means running an orchestrator for one host.
- Kamal routes traffic through its own proxy, which conflicts with
  caddy-tailscale's per-site tailnet nodes.
- Guix System follows the NixOS model with fewer packages and service
  modules.

## Open questions

The following questions need answers before a choice:

- Can a bootc image or a Fedora CoreOS image boot on Linode, and how is
  it installed?
- Is learning Nix, or building frork, the larger cost?
- Does whole-system rollback matter for this host, or is re-converging
  good enough?
