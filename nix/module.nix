self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.virtualisation.migrant;
  migrantPkg = cfg.package;

  # NixOS spells strict reverse-path filtering both ways.
  rp = config.networking.firewall.checkReversePath;
  rpIsStrict = rp == true || rp == "strict";

  # Every bare command the packaged hooks invoke, by package. Hooks never call
  # virsh (calling it against a domain from that domain's own hook deadlocks),
  # so libvirt is deliberately absent.
  hookPath = lib.makeBinPath [
    pkgs.iptables
    pkgs.nftables
    pkgs.iproute2
    pkgs.procps
    pkgs.wireguard-tools
    pkgs.findutils
    pkgs.util-linux
    pkgs.python3
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gawk
  ];

  # Pin PATH to exactly hookPath (a root firewall hook must not inherit the
  # caller's PATH) and exec the staged hook, preserving stdin and argv. Its
  # shebang was patched to the store bash at build time, so NixOS having no
  # /bin/bash is fine.
  wrapHook =
    rel:
    pkgs.writeShellScript "migrant-hook-${builtins.replaceStrings [ "/" ] [ "-" ] rel}" ''
      export PATH=${hookPath}
      exec ${migrantPkg}/share/migrant/hooks/${rel} "$@"
    '';
in
{
  options.virtualisation.migrant = {
    enable = lib.mkEnableOption "migrant libvirt/QEMU VM manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.system}.migrant;
      defaultText = lib.literalExpression "migrant-nix flake package";
      description = "The migrant package to install.";
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "brett" ];
      description = ''
        Users added to the libvirt group so they can run migrant unprivileged.
        Re-login is required after the first rebuild for the group to take effect.
      '';
    };

    installHookDirCompatShim = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install a non-executable placeholder at
        /etc/libvirt/hooks/qemu.d/migrant-loop.

        migrant's ensure_shared_folder_images() tests that path before starting
        a VM with shared-folder isolation, but NixOS dispatches hooks from
        /var/lib/libvirt/hooks, so without the placeholder that check reports a
        spurious "run 'migrant setup' first".

        Non-executability is load-bearing: it satisfies the file test while
        making dispatch impossible, so there is no risk of the loop hook running
        twice even if libvirt were to scan /etc/libvirt/hooks.

        Set to false once the pinned migrant honours MIGRANT_HOOKS_DIR, which
        the package already sets.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ migrantPkg ];

    virtualisation.libvirtd = {
      enable = true;
      qemu.package = pkgs.qemu_kvm;
      # Shared folders use virtiofs; libvirt spawns virtiofsd, locating it via
      # the vhost-user descriptors from vhostUserPackages. qemu_kvm does not
      # bundle virtiofsd, so without this a shared-folder domain — migrant's
      # core host<->guest data channel — fails to start.
      qemu.vhostUserPackages = [ pkgs.virtiofsd ];
    };

    users.groups.libvirt.members = cfg.users;

    # root:libvirt and group-writable, so unprivileged migrant (a group member)
    # can create per-VM state. Modes match cmd_setup, including setgid on
    # /etc/migrant.
    systemd.tmpfiles.rules = [
      "d /etc/migrant 2770 root libvirt -"
      "d /var/lib/libvirt/images 0775 root libvirt -"
    ];

    # firewall_backend intentionally unset: libvirt's default is right here, and
    # cmd_setup likewise only overrides it on legacy-iptables hosts.

    # NixOS's firewall filters reverse paths strictly (-m rpfilter --validmark).
    # A WireGuard VM's egress is fwmark-routed through a table holding only
    # "default dev mg-wg-*"; the decrypted replies arrive on that interface
    # unmarked, so a strict lookup resolves them to the physical NIC and drops
    # every one. Loose still drops unroutable sources. This netfilter match is
    # independent of the per-interface rp_filter sysctl the hook sets.
    networking.firewall.checkReversePath = lib.mkDefault "loose";

    # mkDefault yields to a host that sets it back, and the resulting failure is
    # silent — the tunnel handshakes and counts bytes while nothing gets through.
    warnings = lib.optional rpIsStrict ''
      virtualisation.migrant: networking.firewall.checkReversePath is strict, so
      WireGuard VMs will not receive return traffic. Set it to "loose".
    '';

    # Register hooks via libvirtd's own option: NixOS symlinks them into
    # /var/lib/libvirt/hooks/<driver>.d, where its libvirt dispatches from and
    # where it wipes anything not registered here. /etc/libvirt/hooks via
    # environment.etc is never dispatched on NixOS.
    virtualisation.libvirtd.hooks.qemu."migrant" = wrapHook "qemu.d/migrant";
    virtualisation.libvirtd.hooks.qemu."migrant-loop" = wrapHook "qemu.d/migrant-loop";
    virtualisation.libvirtd.hooks.network."migrant" = wrapHook "network.d/migrant";

    # See the option description. Non-executable by design.
    environment.etc."libvirt/hooks/qemu.d/migrant-loop" = lib.mkIf cfg.installHookDirCompatShim {
      text = ''
        # Placeholder, not a hook. The real migrant loop hook is registered at
        # /var/lib/libvirt/hooks/qemu.d/migrant-loop, which is where NixOS's
        # libvirt dispatches from. This file exists only so migrant's
        # ensure_shared_folder_images() file test succeeds; it is deliberately
        # not executable. See virtualisation.migrant.installHookDirCompatShim.
      '';
      mode = "0444";
    };

    # Define and autostart the migrant network idempotently from the packaged
    # XML. NixOS has no first-class "define a libvirt network" option, so a root
    # oneshot ordered after libvirtd does it declaratively at activation —
    # notably without sudo, which migrant's lifecycle commands must never need.
    systemd.services.migrant-network = {
      description = "Define the migrant libvirt network";
      after = [ "libvirtd.service" ];
      requires = [ "libvirtd.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
        pkgs.libvirt
        pkgs.gnugrep
        pkgs.coreutils
      ];
      environment.LIBVIRT_DEFAULT_URI = "qemu:///system";
      script = ''
        if ! virsh net-info migrant >/dev/null 2>&1; then
          virsh net-define ${migrantPkg}/share/migrant/network.xml
        fi
        virsh net-autostart migrant
        virsh net-list --name | grep -qx migrant || virsh net-start migrant
      '';
    };
  };
}
