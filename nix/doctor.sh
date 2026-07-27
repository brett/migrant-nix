#!/usr/bin/env bash
set -euo pipefail

# migrant host doctor for NixOS.
#
# The NixOS module owns privileged setup, so this must never call sudo — it only
# verifies the module's artifacts. A missing module-provided prerequisite is
# fatal (EX_CONFIG); host-hardware gaps (KVM) and recoverable states are warnings.
#
# Output follows migrant's own cmd_status/cmd_setup format: aligned key: value
# pairs, indented sub-fields, [ERROR]/[WARNING] markers, never colors.

kw=21   # key column width
skw=19  # sub-field key column width (kw - 2 for the indent)
problems=0
warnings=0

# NixOS dispatches libvirt hooks from /var/lib/libvirt/hooks, not /etc/libvirt/hooks.
hooks_dir=/var/lib/libvirt/hooks

row()  { printf '%-*s%s\n' "$kw" "$1" "$2"; }
sub()  { printf '  %-*s%s\n' "$skw" "$1" "$2"; }
bad()  { problems=$(( problems + 1 )); }
warn() { warnings=$(( warnings + 1 )); }

echo "migrant host setup on NixOS is managed by the migrant NixOS module."
echo "This command only verifies the module was applied (it makes no changes)."
echo ""

# KVM — WARNING not fatal: it is host hardware the module cannot provide, and a
# nixosTest/CI builder legitimately runs under TCG without /dev/kvm.
if [[ -r /dev/kvm ]]; then
  row "kvm:" "ok"
else
  row "kvm:" "unavailable [WARNING]"
  sub "note:" "VMs cannot run without KVM (normal in nested/CI builders)"
  warn
fi

# libvirtd + virtlogd. Socket activation means either the socket or the service
# being active is sufficient.
for unit in libvirtd virtlogd; do
  if systemctl is-active --quiet "$unit.socket" 2>/dev/null \
    || systemctl is-active --quiet "$unit.service" 2>/dev/null; then
    row "$unit:" "active"
  else
    row "$unit:" "NOT ACTIVE [ERROR]"
    bad
  fi
done

# libvirt group — check PROCESS credentials, not the account database, so a
# pending re-login after the first rebuild is reported rather than hidden.
if id -nG | grep -qw libvirt; then
  row "libvirt group:" "ok"
else
  row "libvirt group:" "MISSING [ERROR]"
  sub "hint:" "add your user to virtualisation.migrant.users, then re-login"
  bad
fi

# /etc/migrant — the data channel to the privileged hooks (root:libvirt, setgid).
if [[ -d /etc/migrant && "$(stat -c '%G' /etc/migrant)" == libvirt \
      && "$(stat -c '%a' /etc/migrant)" == 2770 ]]; then
  row "/etc/migrant:" "ok"
else
  row "/etc/migrant:" "MISSING/wrong perms [ERROR]"
  bad
fi

# images dir — owner:group:mode AND writability (parity with cmd_setup: root:libvirt 0775)
if [[ -d /var/lib/libvirt/images && "$(stat -c '%G' /var/lib/libvirt/images)" == libvirt \
      && "$(stat -c '%a' /var/lib/libvirt/images)" == 775 && -w /var/lib/libvirt/images ]]; then
  row "images dir:" "ok"
else
  row "images dir:" "MISSING/wrong perms [ERROR]"
  bad
fi

# hooks — must be executable; an empty or non-executable file at the path is not
# enough, and libvirt would silently skip it.
for hook in qemu.d/migrant qemu.d/migrant-loop network.d/migrant; do
  if [[ -x "$hooks_dir/$hook" ]]; then
    row "hook ${hook}:" "installed"
  else
    row "hook ${hook}:" "MISSING/not executable [ERROR]"
    bad
  fi
done

# command closure — the wrapped migrant must resolve everything lifecycle needs.
for cmd in virsh virt-install qemu-img mkfs.ext4 xorriso wg; do
  if command -v "$cmd" >/dev/null 2>&1; then
    row "cmd ${cmd}:" "ok"
  else
    row "cmd ${cmd}:" "MISSING [ERROR]"
    bad
  fi
done

# virtiofsd — libvirt spawns it for shared folders, locating it through the
# vhost-user descriptors the module wires. Without it a shared-folder VM (the
# core host<->guest channel) fails to start.
vhostuser_found=false
for descriptor in /var/lib/qemu/vhost-user/*virtiofsd* /run/libvirt/qemu/vhost-user/*virtiofsd*; do
  if [[ -e "$descriptor" ]]; then
    vhostuser_found=true
    break
  fi
done
if [[ "$vhostuser_found" == true ]]; then
  row "virtiofsd:" "ok"
else
  row "virtiofsd:" "not wired [WARNING]"
  sub "hint:" "shared folders need virtualisation.libvirtd.qemu.vhostUserPackages"
  warn
fi

# migrant network. Needs libvirt group membership; if that is missing this may
# read as NOT DEFINED, which the group check above already explains.
if virsh net-info migrant >/dev/null 2>&1; then
  if virsh net-list --name 2>/dev/null | grep -qx migrant; then
    row "migrant network:" "active"
  else
    row "migrant network:" "defined, not active [WARNING]"
    sub "hint:" "systemctl restart migrant-network"
    warn
  fi
  # A network defined before the IPv6 ULA was added is left as-is (the unit does
  # not redefine an existing net), so NETWORK_IPV6=nat would be silently off.
  if ! virsh net-dumpxml migrant 2>/dev/null | grep -q 'fdca:6d16:2b1a'; then
    sub "note:" "network predates IPv6 ULA — recreate it to use NETWORK_IPV6=nat"
    warn
  fi
else
  row "migrant network:" "NOT DEFINED [ERROR]"
  sub "hint:" "systemctl restart migrant-network"
  bad
fi

# firewall backend — informational, never fatal. The module leaves it unset, as
# cmd_setup does on any host that is not legacy-iptables.
backend=$(grep -oP '(?<=^\s*firewall_backend\s=\s")[^"]+' /etc/libvirt/network.conf 2>/dev/null | head -1 || true)
row "firewall backend:" "${backend:-default (libvirt-selected)}"

echo ""
if (( problems > 0 )); then
  echo "$problems problem(s). Set 'virtualisation.migrant.enable = true' (and add" >&2
  echo "your user to virtualisation.migrant.users), then nixos-rebuild switch." >&2
  exit 78  # EX_CONFIG
fi
if (( warnings > 0 )); then
  echo "Host prerequisites satisfied ($warnings warning(s) — see above)."
else
  echo "All migrant host prerequisites satisfied."
fi
