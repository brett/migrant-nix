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
specific ownership, installs three libvirt hooks, and defines a NAT network.
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
migrant-doctor
```

It checks libvirtd and virtlogd, group membership, `/etc/migrant`, the images
directory, all three hooks, the runtime command closure, virtiofsd, and the
`migrant` network. A missing module-provided prerequisite is fatal (exit 78);
host-hardware and degraded conditions — no KVM, a network predating the IPv6
subnet, virtiofsd not wired — are warnings. It never calls `sudo` and never
changes anything.

From there, every other migrant subcommand works as documented upstream:
`migrant up`, `status`, `ssh`, `destroy`, and so on.

## Options

| Option | Default | |
| --- | --- | --- |
| `virtualisation.migrant.enable` | `false` | Enable the module. |
| `virtualisation.migrant.users` | `[ ]` | Users added to the `libvirt` group. Requires re-login. |
| `virtualisation.migrant.package` | this flake's `migrant` | The migrant package to install. |
| `virtualisation.migrant.installHookDirCompatShim` | `true` | See "Upstream changes" below. |

## Notes

- The module sets `networking.firewall.checkReversePath = "loose"`. NixOS's
  default is strict (`-m rpfilter --validmark`), which drops the replies
  returning down a VM's WireGuard tunnel: migrant fwmark-routes that egress
  through a table holding only the tunnel interface, and the decrypted replies
  arrive unmarked, so a strict lookup resolves them to the physical NIC. The
  module warns if something sets it back to strict, because the failure is
  otherwise silent — the tunnel handshakes and counts bytes while nothing gets
  through.
- libvirt's `firewall_backend` is left unset, matching what upstream
  `cmd_setup` does on any host that is not legacy-iptables.
- For parity with migrant's primary target (Arch with `linux-hardened`),
  consider `boot.kernelPackages = pkgs.linuxPackages_hardened`.
- `migrant setup` does not work on NixOS and is not supposed to. Depending on
  the pinned upstream it either runs `migrant-doctor` or exits 69 without
  touching anything; either way it never performs imperative setup.

## Upstream changes

The package sets two environment variables that upstream migrant does not read
yet. Both are inert without them and start working the day they merge:

- **`MIGRANT_SETUP_COMMAND`** — makes `migrant setup` hand off to
  `migrant-doctor`, so there is one command name across every distro.
- **`MIGRANT_HOOKS_DIR`** — tells migrant where libvirt actually dispatches
  hooks. NixOS uses `/var/lib/libvirt/hooks`; upstream hardcodes
  `/etc/libvirt/hooks` in `ensure_shared_folder_images()`, which would report a
  spurious "run `migrant setup` first" for any VM with shared-folder isolation.
  Until it lands, the module installs a **non-executable** placeholder at
  `/etc/libvirt/hooks/qemu.d/migrant-loop` to satisfy that file test. Non-
  executability is the point: it cannot be dispatched, so the loop hook can
  never run twice. Set `installHookDirCompatShim = false` once the pinned
  migrant honours `MIGRANT_HOOKS_DIR`.

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

Run `nixfmt` on any `.nix` file you touch. `nix/doctor.sh` is built with
`writeShellApplication`, so shellcheck runs at build time and must be clean.

## License

migrant is released under the Unlicense; this packaging follows it.
