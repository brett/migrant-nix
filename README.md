# migrant-nix

NixOS packaging for [migrant](https://github.com/pigmonkey/migrant) — a
single-file bash tool for running secure, ephemeral libvirt/QEMU VMs, designed
for coding agents that may be malicious or compromised.

This repository is not migrant. It packages the upstream script, wires the
libvirt hooks it depends on, and reproduces its one-time host setup as
declarative NixOS configuration. Upstream is maintained by
[pigmonkey](https://github.com/pigmonkey) and does not target NixOS; report bugs
in migrant itself upstream, and bugs in the packaging here.

## Why a module and not just a package

`migrant setup` is imperative host configuration: it enables libvirtd, adds you
to the `libvirt` group, creates `/etc/migrant` and the images directory with
specific ownership, pins libvirt's firewall backend, loads `br_netfilter` and
its two sysctls, installs three libvirt hooks, and defines a NAT network.
On NixOS that work belongs in the system configuration, so this flake provides a
module that does all of it declaratively — plus a read-only `migrant-doctor`
that verifies the result.

The hooks matter: they are what enforces migrant's isolation boundary
(per-VM firewall chains, MAC blocking, WireGuard policy routing, NAT66
refcounting, shared-folder loop mounts). A migrant install without working hooks
starts VMs with no isolation at all.

## Usage

```nix
# flake.nix
{
  inputs.migrant-nix.url = "github:brett/migrant-nix";

  outputs = { self, nixpkgs, migrant-nix, ... }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        migrant-nix.nixosModules.default
        {
          virtualisation.migrant.enable = true;
          virtualisation.migrant.users = [ "youruser" ];
        }
      ];
    };
  };
}
```

```bash
sudo nixos-rebuild switch
```

Log out and back in after the first rebuild so your shell picks up the `libvirt`
group, then verify:

```bash
migrant setup
```

On other distros that command configures the host. Here the module already has,
so it runs a read-only doctor instead (also available directly as
`migrant-doctor`).

It checks libvirtd and virtlogd, group membership, `/etc/migrant`, the images
directory, all three hooks, the runtime command closure, virtiofsd, the
`migrant` network, libvirt's firewall backend, and bridge netfilter. A missing
module-provided prerequisite is fatal (exit 78); host-hardware and degraded
conditions — no KVM, a network predating the IPv6 subnet, virtiofsd not wired —
are warnings. It never calls `sudo` and never changes anything.

From there, every other migrant subcommand works as documented upstream:
`migrant up`, `status`, `ssh`, `destroy`, and so on.

## Options

| Option | Default | |
| --- | --- | --- |
| `virtualisation.migrant.enable` | `false` | Enable the module. |
| `virtualisation.migrant.users` | `[ ]` | Users added to the `libvirt` group. Requires re-login. |
| `virtualisation.migrant.package` | this flake's `migrant` | The migrant package to install. |

## Notes

- The module sets `networking.firewall.checkReversePath = "loose"`. NixOS's
  default is strict (`-m rpfilter --validmark`), which drops the replies
  returning down a VM's WireGuard tunnel: migrant fwmark-routes that egress
  through a table holding only the tunnel interface, and the decrypted replies
  arrive unmarked, so a strict lookup resolves them to the physical NIC. The
  module warns if something sets it back to strict, because the failure is
  otherwise silent — the tunnel handshakes and counts bytes while nothing gets
  through.
- The module pins `virtualisation.libvirtd.firewallBackend = "iptables"`, which
  migrant's hooks require; a host that enables nftables gets an eval conflict.
- For parity with migrant's primary target (Arch with `linux-hardened`),
  consider `boot.kernelPackages = pkgs.linuxPackages_hardened`.
- `migrant setup` never performs imperative setup here. The package points
  `MIGRANT_SETUP_COMMAND` at `migrant-doctor`, so it runs the doctor instead.

## Environment

The package wraps `migrant` with two overrides, both upstream since
[#14](https://github.com/pigmonkey/migrant/pull/14). The build asserts the
pinned migrant reads them, so an older pin fails here rather than silently
losing them at runtime.

- **`MIGRANT_SETUP_COMMAND`** → `migrant-doctor`, so `migrant setup` is the
  same command on every distro.
- **`LIBVIRT_CONF_DIR`** → `/var/lib/libvirt`, libvirt's sysconfdir rather than
  its hooks subdirectory: nixpkgs builds libvirt with `--sysconfdir=/var/lib`,
  so `hooks/` and `network.conf` both live under it.

## Development

```bash
nix flake check          # cli-closure guard + the module nixosTest
nix run '.#test-vm'      # disposable NixOS host with the module enabled
nix run '.#test-vm-check' # end-to-end: doctor -> real agent VM -> isolation asserts
```

`nix flake check` needs KVM. The `module` test boots a NixOS guest, drives the
real packaged hooks through `prepare -> started -> release` for isolation,
WireGuard, NAT66, host-access, and the loop image, starts a virtiofs domain,
runs a real `migrant destroy` against a TCG domain, and asserts the doctor
passes as an unprivileged user with no `sudo` on the system.
`module-nftables-host` re-checks the host setup with nftables enabled.

### Bumping the pinned migrant

```bash
nix flake update migrant
nix flake check
```

`nix flake check` is the gate, and it is not optional. The module encodes
assumptions about upstream — hook filenames, `/etc/migrant` permissions, the
network XML, and `hookPath`, the exact set of commands the hooks shell out to.
A hook that gains a command missing from `hookPath` fails only when libvirt
dispatches it, and the failure mode is a VM starting without isolation rules.
The nixosTest catches that; nothing else will.

`nix/package.nix` additionally asserts at eval time that the five `setup/`
assets still exist upstream, so a rename fails with a clear message instead of
an opaque build error.

### Contributing

Never copy an upstream asset into this repo. The hooks, the network XML, and the
ZSH completion all come from the pinned input's `setup/` directory — wrap or
stage them, never vendor them, or they silently go stale against upstream.

Upstream's `cmd_setup` and `nix/module.nix` are parallel implementations of the
same host setup. When migrant grows a new one:

1. Mirror it as system configuration in `nix/module.nix`
2. Add a verification row to `nix/doctor.sh`
3. Add any new command the hooks call to `hookPath` in `nix/module.nix`, and any
   new command the CLI calls to `runtimeDeps` in `nix/package.nix`
4. Extend `checks/default.nix` to cover it

Run `nixfmt` on any `.nix` file you touch. `nix/doctor.sh` is covered by the
`doctor-shellcheck` flake check, so shellcheck must be clean.

## License

migrant is released under the Unlicense; this packaging follows it.
