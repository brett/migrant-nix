# The migrant CLI, wrapped for NixOS.
#
# callPackage-shaped on purpose: `src` and `doctor` are the only inputs tied to
# this flake, so a nixpkgs port would swap `src` for fetchFromGitHub and change
# nothing else.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  src,
  doctor, # nix/doctor.sh

  # External commands the CLI shells out to. Guarded by checks.cli-closure —
  # keep it in sync with the script, not with this list's aesthetics.
  libvirt,
  virt-manager,
  qemu_kvm,
  iproute2,
  wireguard-tools,
  openssh,
  ansible,
  libisoburn,
  cdrkit,
  curl,
  iptables,
  nftables,
  e2fsprogs,
  findutils,
  # archive/restore (upstream 35a7c04). zstd is invoked by tar, so it needs its
  # own PATH entry; upstream preflights it and the error text says to run pacman.
  gnutar,
  zstd,
  coreutils,
  gnugrep,
  gnused,
  gawk,
  util-linux,
}:
let
  runtimeDeps = [
    libvirt
    virt-manager
    qemu_kvm
    iproute2
    wireguard-tools
    openssh
    ansible
    libisoburn
    cdrkit
    curl
    iptables
    nftables
    e2fsprogs
    findutils
    gnutar
    zstd
    coreutils
    gnugrep
    gnused
    gawk
    util-linux
  ];

  # Upstream's cmd_setup reads these from setup/. We stage them ourselves, so an
  # upstream rename must fail here with a clear message rather than as an opaque
  # `install` error deep in the build log.
  setupAssets = [
    "qemu-hook"
    "loop-hook"
    "network-hook"
    "network.xml"
    "_migrant"
  ];
  missingAssets = lib.filter (f: !builtins.pathExists "${src}/setup/${f}") setupAssets;

  # The wrapper below is inert unless migrant reads these. Without the check, an
  # older pin silently loses the handoff (cmd_setup would try imperative setup)
  # and the relocated libvirt tree (breaking shared-folder VMs) — both at
  # runtime, on the user's host, rather than here.
  script = builtins.readFile "${src}/migrant";
  requiredVars = [
    "MIGRANT_SETUP_COMMAND"
    "LIBVIRT_CONF_DIR"
  ];

  # NOT lib.hasInfix: it recurses once per character of the haystack, so it
  # stack-overflows on a large file. `migrant` crossed that threshold between
  # 1a53cdf (76,842 bytes, evaluates) and e174b89 (96,703 bytes, overflows) —
  # measured: hasInfix over 76,000 chars returns; over 96,000 it throws
  # "stack overflow (possible infinite recursion)" with no trace, which reads
  # like an upstream bug rather than a limit in this assertion. builtins.split
  # is implemented natively and does not recurse, so it scales with the script.
  containsInfix =
    needle: haystack: builtins.length (builtins.split (lib.escapeRegex needle) haystack) > 1;
  missingVars = lib.filter (v: !containsInfix v script) requiredVars;

  # The libvirt hooks, as their own derivation built from only the three hook
  # files. builtins.path imports each one by content, so this store path moves
  # when a hook's bytes change (or the bash its shebang is patched to), and NOT
  # on an upstream commit that touches only the CLI, nor on a doctor edit. The
  # module restarts libvirtd whenever these paths change, so on a host running
  # VMs that difference is a daemon restart, not cosmetics.
  #
  # Upstream ships the hooks 0644 (its own install_hook chmods at install time)
  # with #!/bin/bash, which does not exist on NixOS. Fix both here, and rename
  # into the layout libvirt dispatches from.
  hookSrc =
    name:
    builtins.path {
      path = "${src}/setup/${name}";
      name = "migrant-${name}";
    };
  # Patches to the hook files (paths relative to the upstream repo root).
  #
  # The shared bridge drop rule: one atomic nft transaction instead of a gate
  # on `nft add chain`, which succeeds on an existing chain and so appended a
  # copy on every VM start (1,705 on gs-ci-1 after two days). Upstream
  # pigmonkey/migrant has the same gate at df2cda8.
  hookPatches = [ ./patches/qemu-hook-bridge-drop-rule-once.patch ];
  hooks = stdenvNoCC.mkDerivation {
    # No version in the name: it would move the path on every bump.
    name = "migrant-hooks";
    dontUnpack = true;
    dontBuild = true;
    # The hook patches apply HERE: this derivation is what libvirt runs. A patch
    # on the package itself would only touch a copy nothing executes, since the
    # package's share/migrant/hooks is a symlink to this derivation.
    installPhase = ''
      runHook preInstall
      mkdir setup
      cp ${hookSrc "qemu-hook"}    setup/qemu-hook
      cp ${hookSrc "loop-hook"}    setup/loop-hook
      cp ${hookSrc "network-hook"} setup/network-hook
      chmod u+w setup/*
      for p in ${lib.concatMapStringsSep " " (p: "${p}") hookPatches}; do
        patch -p1 < "$p"
      done
      install -Dm755 setup/qemu-hook    $out/qemu.d/migrant
      install -Dm755 setup/loop-hook    $out/qemu.d/migrant-loop
      install -Dm755 setup/network-hook $out/network.d/migrant
      patchShebangs $out
      runHook postInstall
    '';
  };
in
assert lib.assertMsg (missingAssets == [ ]) ''
  migrant-nix: the pinned migrant input is missing setup/ assets: ${lib.concatStringsSep ", " missingAssets}
  Upstream may have renamed or moved them. Reconcile nix/package.nix with the
  new layout before bumping the input.
'';
assert lib.assertMsg (missingVars == [ ]) ''
  migrant-nix: the pinned migrant input does not read: ${lib.concatStringsSep ", " missingVars}
  These landed upstream in pigmonkey/migrant#14. Pin a migrant at or after that
  merge, or this package's wrapper silently does nothing.
'';
stdenvNoCC.mkDerivation {
  pname = "migrant";
  version = "0-unstable-2026-09-09";
  inherit src;

  # No patches here: every patched file is a hook, and the hooks are built
  # (and patched) in `hooks` above.

  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 migrant $out/bin/migrant
    # The build sandbox has no /usr/bin/env.
    patchShebangs $out/bin/migrant

    # The hooks are their own derivation (see `hooks` above); keep them
    # reachable at the path they always had.
    mkdir -p $out/share/migrant
    ln -s ${hooks} $out/share/migrant/hooks

    install -Dm644 setup/network.xml $out/share/migrant/network.xml
    install -Dm644 setup/_migrant    $out/share/zsh/site-functions/_migrant

    # The doctor verifies the closure and the libvirt network that migrant
    # itself sees, so it must run with migrant's PATH and URI, not its own.
    install -Dm755 ${doctor} $out/bin/migrant-doctor
    patchShebangs $out/bin/migrant-doctor

    # MIGRANT_SETUP_DIR is deliberately NOT set: `migrant setup` must never
    # attempt imperative host setup here — it hands off to the doctor instead.
    #
    # LIBVIRT_CONF_DIR is the sysconfdir, not the hooks subdirectory: nixpkgs
    # builds libvirt with --sysconfdir=/var/lib, so hooks/ and network.conf both
    # live under it. Asserted present above.
    wrapProgram $out/bin/migrant \
      --prefix PATH : ${lib.makeBinPath runtimeDeps} \
      --set MIGRANT_SETUP_COMMAND $out/bin/migrant-doctor \
      --set LIBVIRT_CONF_DIR /var/lib/libvirt

    wrapProgram $out/bin/migrant-doctor \
      --prefix PATH : ${lib.makeBinPath runtimeDeps} \
      --set LIBVIRT_DEFAULT_URI qemu:///system

    runHook postInstall
  '';

  passthru = { inherit hooks; };

  meta = {
    description = "Secure, ephemeral libvirt/QEMU VM manager for coding agents";
    homepage = "https://github.com/pigmonkey/migrant";
    license = lib.licenses.unlicense;
    platforms = [ "x86_64-linux" ];
    mainProgram = "migrant";
  };
}
