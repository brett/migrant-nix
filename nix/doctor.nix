# migrant-doctor: read-only verification that the migrant NixOS module applied.
#
# systemd is deliberately absent from runtimeInputs: systemctl must come from
# the host's own systemd via the inherited PATH, not a pinned one that could
# outrank it. writeShellApplication prefixes rather than replaces PATH, so the
# host's /run/current-system/sw/bin still resolves.
{
  writeShellApplication,
  libvirt,
  coreutils,
  gnugrep,
}:
writeShellApplication {
  name = "migrant-doctor";
  runtimeInputs = [
    libvirt
    coreutils
    gnugrep
  ];
  text = builtins.readFile ./doctor.sh;
}
