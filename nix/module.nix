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

  # The package's hooks-only derivation, so the wrappers below (and with them
  # the libvirtd restart) move only when a hook does. A package without it —
  # an override predating the split — falls back to the old layout, at the cost
  # of a restart on every change to that package.
  hooksDir = migrantPkg.hooks or "${migrantPkg}/share/migrant/hooks";

  # Pin PATH to exactly hookPath (a root firewall hook must not inherit the
  # caller's PATH) and exec the staged hook, preserving stdin and argv. Its
  # shebang was patched to the store bash at build time, so NixOS having no
  # /bin/bash is fine.
  wrapHook =
    rel:
    pkgs.writeShellScript "migrant-hook-${builtins.replaceStrings [ "/" ] [ "-" ] rel}" ''
      export PATH=${hookPath}
      exec ${hooksDir}/${rel} "$@"
    '';

  # Keyed by path under /var/lib/libvirt/hooks.
  hookWrappers = lib.genAttrs [
    "qemu.d/migrant"
    "qemu.d/migrant-loop"
    "network.d/migrant"
  ] wrapHook;

  # What each hook link should resolve to. Read by migrant-hooks-reload and,
  # via /etc/migrant-nix/hooks, by the doctor.
  hookManifest = pkgs.writeText "migrant-hooks-manifest" (
    lib.concatStrings (lib.mapAttrsToList (rel: path: "${rel} ${path}\n") hookWrappers)
  );
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

    restartLibvirtdOnHookChange = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Restart libvirtd during a switch that changes the migrant hooks.

        NixOS links the hooks into /var/lib/libvirt/hooks from
        libvirtd-config.service, which runs only when libvirtd starts, and it
        never restarts libvirtd on a switch. Without this, a switch that changes
        the hooks leaves the links on the old store paths until libvirtd next
        restarts, and a garbage collection in between leaves them dangling.

        Running VMs are not affected: libvirtd's unit uses KillMode=process, so
        a restart stops only the daemon, and it reattaches to its domains on
        start. Set to false to restart libvirtd yourself; `migrant-doctor` then
        warns while the hooks are stale.
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
    # can create per-VM state. Modes match cmd_setup, including setgid and
    # sticky on /etc/migrant.
    systemd.tmpfiles.rules = [
      "d /etc/migrant 3770 root libvirt -"
      "d /var/lib/libvirt/images 0775 root libvirt -"
    ];

    # The qemu hook positions its INPUT jump relative to libvirt's LIBVIRT_INP
    # chain, which exists only under the iptables backend — under nftables
    # libvirt filters in its own table and the hook refuses to start the VM.
    # cmd_setup pins it unconditionally for the same reason.
    #
    # This must be the option, not a file: libvirtd-config.service copies its
    # generated network.conf over /var/lib/libvirt/network.conf on every start,
    # so anything written there directly is overwritten. The option's default
    # follows networking.nftables.enable, which is exactly the host that needs
    # overriding. A plain definition (not mkForce) so a host that explicitly
    # asks for nftables gets an eval conflict naming both definitions, rather
    # than a silent override or a VM that aborts at start.
    virtualisation.libvirtd.firewallBackend = "iptables";

    # -m physdev matches nothing unless br_netfilter is loaded and bridged
    # traffic is passed to ip(6)tables, so every isolation rule depends on both.
    # The hook re-checks at start and aborts the domain rather than install rules
    # that would never match. systemd-sysctl is ordered after modules-load, so
    # the sysctls land on a loaded module.
    boot.kernelModules = [ "br_netfilter" ];
    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
    };

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
    virtualisation.libvirtd.hooks.qemu."migrant" = hookWrappers."qemu.d/migrant";
    virtualisation.libvirtd.hooks.qemu."migrant-loop" = hookWrappers."qemu.d/migrant-loop";
    virtualisation.libvirtd.hooks.network."migrant" = hookWrappers."network.d/migrant";

    # For the doctor's stale-hook check. Not under /etc/migrant, which is the
    # hooks' state directory, nor /etc/libvirt, which NixOS never reads.
    environment.etc."migrant-nix/hooks".source = hookManifest;

    # libvirtd has restartIfChanged = false, and libvirtd-config.service — the
    # oneshot that re-links the hooks — runs only as a requirement of libvirtd
    # starting, so a switch alone never re-links them. restartTriggers on
    # libvirtd would do nothing: switch-to-configuration skips a unit marked
    # X-RestartIfChanged=false however its file changed, and flipping that to
    # true would also restart libvirtd on every libvirt or config change.
    #
    # Instead this unit embeds the manifest, so switch-to-configuration
    # restarts it exactly when a hook path changes (and starts it the first time
    # it appears). It compares the live links with the manifest and restarts
    # libvirtd only if they differ, which also makes it a no-op at boot, where
    # libvirtd-config has just linked them. try-restart: an idle libvirtd
    # (socket-activated, --timeout 120) re-links on its next start anyway.
    #
    # Wants/After, never Requires: a Requires= on libvirtd would propagate the
    # restart back into this unit while it is still running.
    systemd.services.migrant-hooks-reload = lib.mkIf cfg.restartLibvirtdOnHookChange {
      description = "Restart libvirtd when the migrant hooks change";
      after = [ "libvirtd.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
        pkgs.coreutils
        config.systemd.package
      ];
      script = ''
        stale=""
        while read -r rel want; do
          have=$(readlink "/var/lib/libvirt/hooks/$rel" || true)
          [ "$have" = "$want" ] || stale="$stale $rel"
        done < ${hookManifest}
        if [ -z "$stale" ]; then
          echo "migrant hooks are current"
          exit 0
        fi
        if ! systemctl is-active --quiet libvirtd.service; then
          echo "migrant hooks changed:$stale; libvirtd is idle and links them when it next starts"
          exit 0
        fi
        echo "migrant hooks changed:$stale; restarting libvirtd (running VMs are left alone)"
        systemctl try-restart libvirtd.service
      '';
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
