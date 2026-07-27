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
in
assert lib.assertMsg (missingAssets == [ ]) ''
  migrant-nix: the pinned migrant input is missing setup/ assets: ${lib.concatStringsSep ", " missingAssets}
  Upstream may have renamed or moved them. Reconcile nix/package.nix with the
  new layout before bumping the input.
'';
stdenvNoCC.mkDerivation {
  pname = "migrant";
  version = "0-unstable-2026-07-26";
  inherit src;

  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 migrant $out/bin/migrant
    # The build sandbox has no /usr/bin/env.
    patchShebangs $out/bin/migrant

    # Upstream ships the hooks 0644 (its own install_hook chmods at install
    # time) with #!/bin/bash, which does not exist on NixOS. Fix both here, and
    # rename into the layout libvirt dispatches from.
    install -Dm755 setup/qemu-hook    $out/share/migrant/hooks/qemu.d/migrant
    install -Dm755 setup/loop-hook    $out/share/migrant/hooks/qemu.d/migrant-loop
    install -Dm755 setup/network-hook $out/share/migrant/hooks/network.d/migrant
    patchShebangs $out/share/migrant/hooks

    install -Dm644 setup/network.xml $out/share/migrant/network.xml
    install -Dm644 setup/_migrant    $out/share/zsh/site-functions/_migrant

    # The doctor verifies the closure and the libvirt network that migrant
    # itself sees, so it must run with migrant's PATH and URI, not its own.
    install -Dm755 ${doctor} $out/bin/migrant-doctor
    patchShebangs $out/bin/migrant-doctor

    # MIGRANT_SETUP_DIR is deliberately NOT set: `migrant setup` must never
    # attempt imperative host setup here. Upstream's resolve_setup_dir runs
    # before check_kvm and sudo -v, so on an upstream without the handoff below
    # it exits EX_UNAVAILABLE having changed nothing and prompted for nothing.
    #
    # MIGRANT_SETUP_COMMAND and MIGRANT_HOOKS_DIR are proposed upstream
    # (see README, "Upstream changes"). Both are inert on an upstream that does
    # not read them, and start working the day it does.
    wrapProgram $out/bin/migrant \
      --prefix PATH : ${lib.makeBinPath runtimeDeps} \
      --set MIGRANT_SETUP_COMMAND $out/bin/migrant-doctor \
      --set MIGRANT_HOOKS_DIR /var/lib/libvirt/hooks

    wrapProgram $out/bin/migrant-doctor \
      --prefix PATH : ${lib.makeBinPath runtimeDeps} \
      --set LIBVIRT_DEFAULT_URI qemu:///system

    runHook postInstall
  '';

  meta = {
    description = "Secure, ephemeral libvirt/QEMU VM manager for coding agents";
    homepage = "https://github.com/pigmonkey/migrant";
    license = lib.licenses.unlicense;
    platforms = [ "x86_64-linux" ];
    mainProgram = "migrant";
  };
}
