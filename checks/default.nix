# NixOS integration checks for the migrant module, run by `nix flake check`
# (checks.<system>.{cli-closure,module}). Imported by flake.nix.
#
# This suite is the sole gate on bumping the pinned migrant input: it dispatches
# the real packaged hooks through prepare -> started -> release for every
# isolation feature, so an upstream hook that gains a command missing from the
# module's hookPath fails here rather than silently on a user's host.
#
# Takes the module and package directly rather than reaching into `self`, so it
# would port to nixos/tests/ unchanged.
{
  pkgs,
  module,
  package,
  doctorScript,
}:
let
  # Verification tooling for the hook-driven teardown tests. iptables here is
  # iptables-nft, reading the very tables the wrapped hook wrote.
  testPath = pkgs.lib.makeBinPath [
    pkgs.iptables
    pkgs.nftables
    pkgs.iproute2
    pkgs.wireguard-tools
    pkgs.e2fsprogs
    pkgs.util-linux
    pkgs.coreutils
    pkgs.gnugrep
  ];

  # Drives the qemu hook prepare -> started -> release (domain XML on stdin, as
  # libvirt does) and asserts isolation rules are created on start and removed
  # on release. No nested KVM: physdev rules insert/delete without a live tap.
  teardownTest = pkgs.writeShellScript "migrant-teardown-test" ''
    set -u
    export PATH=${testPath}:$PATH
    HOOK=/var/lib/libvirt/hooks/qemu.d/migrant
    VM=tvm
    MAC=52:54:00:12:34:56
    CHAIN=MIGRANT_$(printf '%s' "$VM" | md5sum | cut -c1-8)
    CHAIN6=MIGRANT6_$(printf '%s' "$VM" | md5sum | cut -c1-8)
    fail() { echo "TEARDOWN TEST FAIL: $*" >&2; echo "--- hook.log ---" >&2; cat /run/migrant/hook.log >&2 2>/dev/null || true; exit 1; }

    mkdir -p /etc/migrant/$VM
    : > /etc/migrant/$VM/network-isolation
    cat > /tmp/dom.xml <<'XML'
    <domain type='kvm'>
      <name>tvm</name>
      <description>managed-by=migrant</description>
      <devices>
        <interface type='network'>
          <mac address='52:54:00:12:34:56'/>
          <target dev='vnet0'/>
        </interface>
      </devices>
    </domain>
    XML

    # prepare: MAC must be blocked at the bridge
    "$HOOK" "$VM" prepare begin - < /tmp/dom.xml || fail "prepare hook exit $?"
    nft list set bridge migrant blocked_macs 2>/dev/null | grep -q "$MAC" \
      || fail "prepare: MAC not in blocked_macs"

    # started: rules applied, state recorded, MAC unblocked
    "$HOOK" "$VM" started begin - < /tmp/dom.xml || fail "started hook exit $?"
    iptables -nL "$CHAIN" >/dev/null 2>&1 || fail "started: per-VM chain $CHAIN missing"
    # Shared and link-local space is rejected alongside RFC 1918.
    for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
      iptables -S FORWARD | grep 'physdev-in vnet0' | grep -q "$net" \
        || fail "started: FORWARD reject for $net missing"
    done
    ip6tables -S FORWARD | grep -q 'physdev-in vnet0 -j DROP' \
      || fail "started: IPv6 FORWARD DROP missing"
    # guest->host IPv6: the per-VM CHAIN6 jump and the ICMPv6 policy above it.
    ip6tables -S INPUT | grep -q "physdev-in vnet0 -j $CHAIN6" \
      || fail "started: IPv6 INPUT jump to $CHAIN6 missing"
    # Field order and the protocol's spelling are both iptables' choice, so match
    # on the parts rather than a rendered rule.
    ip6tables -S INPUT | grep 'physdev-in vnet0' | grep -v icmpv6-type \
      | grep -- '-j REJECT' | grep -qE -- '-p (ipv6-icmp|icmpv6|58)' \
      || fail "started: ICMPv6 catch-all reject missing"
    # The hook accepts exactly eight types (ND 133-136 and PMTUD/error 1-4).
    # Counted rather than named: iptables renders the type as a name of its own
    # choosing, so asserting one by one would test that spelling, not the policy.
    icmp6_accepts=$(ip6tables -S INPUT | grep 'physdev-in vnet0' | grep icmpv6-type | grep -c -- '-j ACCEPT')
    [ "$icmp6_accepts" = 8 ] \
      || fail "started: expected 8 ICMPv6 type ACCEPTs, found $icmp6_accepts"
    # The teardown record: remove_rules undoes exactly what is listed here, so a
    # fact the hook stopped writing strands its rule on a recycled tap name.
    [ -f /run/migrant/$VM.state ] || fail "started: state record not written"
    grep -qx 'version=1'    /run/migrant/$VM.state || fail "started: state version not 1"
    grep -qx 'tap=vnet0'    /run/migrant/$VM.state || fail "started: tap not recorded"
    grep -qx "mac=$MAC"     /run/migrant/$VM.state || fail "started: MAC not recorded"
    grep -qx 'isolation=true' /run/migrant/$VM.state || fail "started: isolation not recorded"
    [ "$(cat /run/migrant/$VM.iface 2>/dev/null)" = vnet0 ] \
      || fail "started: iface sentinel not vnet0"
    if nft list set bridge migrant blocked_macs 2>/dev/null | grep -q "$MAC"; then
      fail "started: MAC still blocked after apply_rules"
    fi

    # release: all per-VM isolation state must be torn down
    "$HOOK" "$VM" release end - < /tmp/dom.xml || fail "release hook exit $?"
    iptables -nL "$CHAIN" >/dev/null 2>&1 && fail "release: per-VM chain $CHAIN still exists"
    iptables -S FORWARD | grep -q 'physdev-in vnet0' && fail "release: stale FORWARD rules"
    iptables -S INPUT   | grep -q 'physdev-in vnet0' && fail "release: stale INPUT rules"
    ip6tables -S FORWARD | grep -q 'physdev-in vnet0' && fail "release: stale IPv6 FORWARD rules"
    ip6tables -S INPUT | grep -q 'physdev-in vnet0' && fail "release: stale IPv6 INPUT rules"
    ip6tables -nL "$CHAIN6" >/dev/null 2>&1 && fail "release: per-VM chain $CHAIN6 still exists"
    iptables -S | grep -q 'MIGRANT_' && fail "release: stray MIGRANT_ chains remain"
    ip6tables -S | grep -q 'MIGRANT6_' && fail "release: stray MIGRANT6_ chains remain"
    nft list set bridge migrant blocked_macs 2>/dev/null | grep -q "$MAC" && fail "release: MAC still in blocked_macs"
    [ -e /run/migrant/$VM.iface ] && fail "release: iface sentinel not removed"
    [ -e /run/migrant/$VM.state ] && fail "release: state record not removed"

    echo "teardown test OK: per-VM rules, chains, blocked MAC, and records removed on release"
  '';

  # (1) WireGuard teardown: interface + fwmark/mangle policy routing.
  wgTeardownTest = pkgs.writeShellScript "migrant-wg-teardown-test" ''
    set -u
    export PATH=${testPath}:$PATH
    HOOK=/var/lib/libvirt/hooks/qemu.d/migrant
    VM=wgvm
    IFACE=mg-wg-$(printf '%s' "$VM" | md5sum | cut -c1-7)
    TABLE=$((16#$(printf '%s' "$VM" | md5sum | cut -c1-7)))
    fail() { echo "WG TEST FAIL: $*" >&2; cat /run/migrant/hook.log >&2 2>/dev/null || true; exit 1; }

    mkdir -p /etc/migrant/$VM
    : > /etc/migrant/$VM/network-isolation
    : > /etc/migrant/$VM/wireguard.conf
    priv=$(wg genkey); peerpub=$(wg genkey | wg pubkey)
    cat > /etc/migrant/$VM/wireguard-wg.conf <<EOF
    [Interface]
    PrivateKey = $priv
    [Peer]
    PublicKey = $peerpub
    AllowedIPs = 0.0.0.0/0
    Endpoint = 127.0.0.1:51820
    EOF
    chmod 600 /etc/migrant/$VM/wireguard-wg.conf
    printf '%s' '10.66.66.2/24' > /etc/migrant/$VM/wireguard-address
    printf '%s' "<domain type='kvm'><name>wgvm</name><description>managed-by=migrant</description><devices><interface type='network'><mac address='52:54:00:aa:bb:cc'/><target dev='vnet1'/></interface></devices></domain>" > /tmp/wg.xml

    "$HOOK" "$VM" prepare begin - < /tmp/wg.xml || fail "prepare exit $?"
    ip link show "$IFACE" >/dev/null 2>&1 || fail "prepare: wg iface $IFACE not created"

    "$HOOK" "$VM" started begin - < /tmp/wg.xml || fail "started exit $?"
    iptables -t mangle -S PREROUTING | grep -q 'physdev-in vnet1' || fail "started: mangle MARK rule missing"
    ip rule list | grep -q "lookup $TABLE" || fail "started: fwmark policy rule missing"
    ip route show table "$TABLE" | grep -q . || fail "started: WG routing table empty"
    [ -e /run/migrant/$VM.wgmark ] || fail "started: wgmark sentinel missing"

    "$HOOK" "$VM" release end - < /tmp/wg.xml || fail "release exit $?"
    ip link show "$IFACE" >/dev/null 2>&1 && fail "release: wg iface $IFACE still present"
    iptables -t mangle -S PREROUTING | grep -q 'physdev-in vnet1' && fail "release: stale mangle rule"
    ip rule list | grep -q "lookup $TABLE" && fail "release: stale fwmark policy rule"
    [ -n "$(ip route show table "$TABLE" 2>/dev/null)" ] && fail "release: WG routing table not flushed"
    [ -e /run/migrant/$VM.iface ] && fail "release: iface sentinel not removed"
    [ -e /run/migrant/$VM.wgmark ] && fail "release: wgmark sentinel not removed"
    echo "WG teardown OK: iface, fwmark rule, routing table, and sentinels all removed on release"
  '';

  # (2) NAT66 teardown: shared IPv6 MASQUERADE + per-VM v6 rules (refcounted).
  nat66TeardownTest = pkgs.writeShellScript "migrant-nat66-teardown-test" ''
    set -u
    export PATH=${testPath}:$PATH
    HOOK=/var/lib/libvirt/hooks/qemu.d/migrant
    VM=natvm
    ULA='fdca:6d16:2b1a::/64'
    fail() { echo "NAT66 TEST FAIL: $*" >&2; cat /run/migrant/hook.log >&2 2>/dev/null || true; exit 1; }

    mkdir -p /etc/migrant/$VM
    : > /etc/migrant/$VM/network-isolation
    : > /etc/migrant/$VM/network-ipv6
    PRE_FWD=$(cat /proc/sys/net/ipv6/conf/all/forwarding)
    printf '%s' "<domain type='kvm'><name>natvm</name><description>managed-by=migrant</description><devices><interface type='network'><mac address='52:54:00:dd:ee:ff'/><target dev='vnet2'/></interface></devices></domain>" > /tmp/nat.xml

    "$HOOK" "$VM" prepare begin - < /tmp/nat.xml || fail "prepare exit $?"
    "$HOOK" "$VM" started begin - < /tmp/nat.xml || fail "started exit $?"
    ip6tables -t nat -S POSTROUTING | grep -q "$ULA" || fail "started: NAT66 MASQUERADE missing"
    test -f /run/migrant/nat66/$VM || fail "started: nat66 refcount sentinel missing"
    ip6tables -S FORWARD | grep 'physdev-in vnet2' | grep -qi 'fc00::/7' || fail "started: v6 FORWARD reject missing"
    [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding)" = 1 ] || fail "started: IPv6 forwarding not enabled"

    "$HOOK" "$VM" release end - < /tmp/nat.xml || fail "release exit $?"
    ip6tables -t nat -S POSTROUTING | grep -q "$ULA" && fail "release: stale MASQUERADE (last VM should remove it)"
    test -e /run/migrant/nat66/$VM && fail "release: stale nat66 sentinel"
    ip6tables -S FORWARD | grep -q 'physdev-in vnet2' && fail "release: stale v6 FORWARD rules"
    [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding)" = "$PRE_FWD" ] || fail "release: IPv6 forwarding not restored to $PRE_FWD"
    [ -e /run/migrant/nat66/.fwd-prev ] && fail "release: .fwd-prev not removed (last VM)"
    echo "NAT66 teardown OK: MASQUERADE + v6 rules removed, IPv6 forwarding restored to $PRE_FWD"
  '';

  # (3) host-access teardown: allow-host-port DNAT + allow-lan-host ACCEPT.
  hostAccessTeardownTest = pkgs.writeShellScript "migrant-hostaccess-teardown-test" ''
    set -u
    export PATH=${testPath}:$PATH
    HOOK=/var/lib/libvirt/hooks/qemu.d/migrant
    VM=havm
    fail() { echo "HOST-ACCESS TEST FAIL: $*" >&2; cat /run/migrant/hook.log >&2 2>/dev/null || true; exit 1; }

    mkdir -p /etc/migrant/$VM
    : > /etc/migrant/$VM/network-isolation
    printf '%s\n%s\n' 'allow-host-port tcp/9999' 'allow-lan-host 10.0.0.5' > /etc/migrant/$VM/host-access
    printf '%s' "<domain type='kvm'><name>havm</name><description>managed-by=migrant</description><devices><interface type='network'><mac address='52:54:00:11:22:33'/><target dev='vnet3'/></interface></devices></domain>" > /tmp/ha.xml

    "$HOOK" "$VM" prepare begin - < /tmp/ha.xml || fail "prepare exit $?"
    "$HOOK" "$VM" started begin - < /tmp/ha.xml || fail "started exit $?"
    iptables -t nat -S PREROUTING | grep 'physdev-in vnet3' | grep -q '9999' || fail "started: allow-host-port DNAT missing"
    iptables -S FORWARD | grep 'physdev-in vnet3' | grep -q '10.0.0.5' || fail "started: allow-lan-host ACCEPT missing"

    "$HOOK" "$VM" release end - < /tmp/ha.xml || fail "release exit $?"
    iptables -t nat -S PREROUTING | grep 'physdev-in vnet3' | grep -q '9999' && fail "release: stale DNAT rule"
    iptables -S FORWARD | grep 'physdev-in vnet3' | grep -q '10.0.0.5' && fail "release: stale allow-lan-host rule"
    echo "host-access teardown OK: DNAT + LAN accept created on start, removed on release"
  '';

  # (4) loop-image hook: shared-folder image mounted on prepare, unmounted on release.
  loopHookTest = pkgs.writeShellScript "migrant-loop-hook-test" ''
    set -u
    export PATH=${testPath}:$PATH
    LOOPHOOK=/var/lib/libvirt/hooks/qemu.d/migrant-loop
    VM=loopvm
    SRC=/tmp/lshare
    fail() { echo "LOOP HOOK TEST FAIL: $*" >&2; cat /run/migrant/hook.log >&2 2>/dev/null || true; exit 1; }

    mkdir -p /etc/migrant/$VM          # no *-disabled file -> isolation active
    mkdir -p "$SRC"
    truncate -s 16M "$SRC.img"
    mkfs.ext4 -qF "$SRC.img"
    printf '%s' "<domain type='kvm'><name>loopvm</name><description>managed-by=migrant</description><devices><filesystem type='mount' accessmode='passthrough'><driver type='virtiofs'/><source dir='/tmp/lshare'/><target dir='lshare'/></filesystem></devices></domain>" > /tmp/loop.xml

    "$LOOPHOOK" "$VM" prepare begin - < /tmp/loop.xml || fail "prepare exit $?"
    mountpoint -q "$SRC" || fail "prepare: $SRC not mounted"
    # The right image mounted the wrong way is still only half the isolation.
    findmnt -no OPTIONS "$SRC" | grep -qw nosymfollow || fail "prepare: mounted without nosymfollow"
    # migrant verifies the running VM's shares against this record, so a hook
    # that stops writing it makes every VM fail its post-start check.
    printf '%s\t%s\n' "$SRC" "$SRC.img" | cmp -s - /run/migrant/$VM.shared \
      || fail "prepare: mount record wrong: $(cat /run/migrant/$VM.shared 2>/dev/null)"

    "$LOOPHOOK" "$VM" release end - < /tmp/loop.xml || fail "release exit $?"
    mountpoint -q "$SRC" && fail "release: $SRC still mounted after unmount"
    [ -e /run/migrant/$VM.shared ] && fail "release: mount record not removed"

    # Fail closed: something else already mounted where the image belongs must
    # abort the VM, not leave virtiofsd serving it.
    mount -t tmpfs none "$SRC" || fail "could not stage the decoy mount"
    "$LOOPHOOK" "$VM" prepare begin - < /tmp/loop.xml && fail "prepare accepted a foreign mount"
    umount "$SRC"

    echo "loop hook OK: nosymfollow mount + record on prepare, removed on release, foreign mount refused"
  '';

  # (5) Lifecycle teardown: `migrant destroy` on a real (TCG) domain fires
  # pre/post-down hooks and cleans up rules + config. destroy is representative
  # — halt/reset share do_graceful_shutdown/teardown_vm.
  lifecycleTest = pkgs.writeShellScript "migrant-lifecycle-test" ''
    set -u
    export PATH=${
      pkgs.lib.makeBinPath [
        pkgs.libvirt
        pkgs.iptables
        pkgs.coreutils
        pkgs.gnugrep
      ]
    }:$PATH
    export LIBVIRT_DEFAULT_URI=qemu:///system
    VM=lcvm
    VMDIR=/tmp/$VM
    CHAIN=MIGRANT_$(printf '%s' "$VM" | md5sum | cut -c1-8)
    fail() { echo "LIFECYCLE TEST FAIL: $*" >&2; cat /run/migrant/hook.log >&2 2>/dev/null || true; exit 1; }

    rm -f /run/migrant-lc-predown /run/migrant-lc-postdown
    mkdir -p $VMDIR/hooks
    printf '%s\n%s\n%s\n' 'VM_NAME="lcvm"' 'NETWORKS=("network=migrant")' 'NETWORK_ISOLATION=true' > $VMDIR/Migrantfile
    printf '#!/bin/sh\ntouch /run/migrant-lc-predown\n'  > $VMDIR/hooks/pre-down
    printf '#!/bin/sh\ntouch /run/migrant-lc-postdown\n' > $VMDIR/hooks/post-down
    chmod +x $VMDIR/hooks/pre-down $VMDIR/hooks/post-down

    mkdir -p /etc/migrant/$VM
    : > /etc/migrant/$VM/network-isolation

    printf '%s' "<domain type='qemu'><name>lcvm</name><description>managed-by=migrant</description><memory unit='MiB'>128</memory><vcpu>1</vcpu><os><type arch='x86_64' machine='pc'>hvm</type></os><devices><interface type='network'><mac address='52:54:00:77:88:99'/><source network='migrant'/><model type='virtio'/></interface><serial type='pty'/></devices></domain>" > /tmp/lcdom.xml

    virsh define /tmp/lcdom.xml >/dev/null || fail "virsh define"
    virsh start "$VM" >/dev/null || fail "virsh start (TCG domain)"
    # give the started hook a moment to apply rules
    for i in 1 2 3 4 5; do iptables -nL "$CHAIN" >/dev/null 2>&1 && break; sleep 1; done
    iptables -nL "$CHAIN" >/dev/null 2>&1 || fail "start: isolation chain $CHAIN not applied"

    # migrant destroy runs as root (no sudo); fires pre-down, destroys, undefines, post-down
    ( cd "$VMDIR" && migrant destroy ) || fail "migrant destroy exit $?"

    test -e /run/migrant-lc-predown  || fail "pre-down hook did not fire"
    test -e /run/migrant-lc-postdown || fail "post-down hook did not fire"
    virsh dominfo "$VM" >/dev/null 2>&1 && fail "domain still defined after destroy"
    iptables -nL "$CHAIN" >/dev/null 2>&1 && fail "isolation chain not cleaned on destroy"
    [ -d /etc/migrant/$VM ] && fail "managed config /etc/migrant/$VM not removed"
    echo "lifecycle destroy OK: pre/post-down fired, domain + rules + managed config removed"
  '';

  # (opt-out) NETWORK_ISOLATION=false: no managed isolation file -> apply_rules
  # must NOT create any per-VM chain or FORWARD rejects (VM keeps full access).
  noIsolationTest = pkgs.writeShellScript "migrant-noiso-test" ''
    set -u
    export PATH=${testPath}:$PATH
    HOOK=/var/lib/libvirt/hooks/qemu.d/migrant
    VM=noisovm
    CHAIN=MIGRANT_$(printf '%s' "$VM" | md5sum | cut -c1-8)
    fail() { echo "NO-ISO TEST FAIL: $*" >&2; exit 1; }

    mkdir -p /etc/migrant/$VM   # deliberately NO network-isolation / network-ipv6 files
    printf '%s' "<domain type='kvm'><name>noisovm</name><description>managed-by=migrant</description><devices><interface type='network'><mac address='52:54:00:44:55:66'/><target dev='vnet4'/></interface></devices></domain>" > /tmp/noiso.xml

    "$HOOK" "$VM" prepare begin - < /tmp/noiso.xml || fail "prepare exit $?"
    "$HOOK" "$VM" started begin - < /tmp/noiso.xml || fail "started exit $?"
    iptables -nL "$CHAIN" >/dev/null 2>&1 && fail "isolation chain created despite NETWORK_ISOLATION unset"
    iptables -S FORWARD | grep -q 'physdev-in vnet4' && fail "FORWARD rules applied despite isolation off"
    "$HOOK" "$VM" release end - < /tmp/noiso.xml || fail "release exit $?"
    echo "NETWORK_ISOLATION=false OK: opt-out honored, no isolation rules applied"
  '';

  # (shared folders) virtiofsd is wired (module's vhostUserPackages) and a
  # virtiofs domain starts — the core host<->guest channel.
  virtiofsTest = pkgs.writeShellScript "migrant-virtiofs-test" ''
    set -u
    export PATH=${
      pkgs.lib.makeBinPath [
        pkgs.libvirt
        pkgs.coreutils
        pkgs.gnugrep
      ]
    }:$PATH
    export LIBVIRT_DEFAULT_URI=qemu:///system
    VM=vfsvm
    SRC=/tmp/vfsshare
    fail() { echo "VIRTIOFS TEST FAIL: $*" >&2; virsh start "$VM" 2>&1 | head -5 >&2 || true; exit 1; }

    ls /var/lib/qemu/vhost-user/ 2>/dev/null | grep -qi virtiofsd \
      || fail "virtiofsd vhost-user descriptor not installed (module vhostUserPackages)"

    mkdir -p "$SRC"
    mkdir -p /etc/migrant/$VM
    : > /etc/migrant/$VM/shared-folder-isolation-disabled   # loop hook no-op; tests transport only
    # Real migrant VMs always have a NIC; include one so the qemu hook's MAC
    # extraction succeeds (a NIC-less managed domain is not a real scenario).
    printf '%s' "<domain type='qemu'><name>vfsvm</name><description>managed-by=migrant</description><memory unit='MiB'>256</memory><vcpu>1</vcpu><memoryBacking><source type='memfd'/><access mode='shared'/></memoryBacking><os><type arch='x86_64' machine='pc'>hvm</type></os><devices><interface type='network'><mac address='52:54:00:ab:cd:ef'/><source network='migrant'/><model type='virtio'/></interface><filesystem type='mount' accessmode='passthrough'><driver type='virtiofs'/><source dir='/tmp/vfsshare'/><target dir='vfsshare'/></filesystem></devices></domain>" > /tmp/vfs.xml

    virsh define /tmp/vfs.xml >/dev/null || fail "define"
    virsh start "$VM" >/dev/null 2>&1 || fail "virtiofs domain failed to start (virtiofsd not working)"
    virsh domstate "$VM" | grep -q running || fail "virtiofs domain not running"
    virsh destroy "$VM" >/dev/null 2>&1 || true
    virsh undefine "$VM" >/dev/null 2>&1 || true
    echo "virtiofs OK: virtiofsd wired and a shared-folder domain starts"
  '';
in
{
  doctor-shellcheck =
    pkgs.runCommand "migrant-doctor-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; }
      ''
        shellcheck ${doctorScript}
        touch $out
      '';

  cli-closure = pkgs.runCommand "migrant-cli-closure" { } ''
    # Guards runtimeDeps: every external command the CLI shells out to must
    # resolve on the wrapped PATH. Keep the list current with the script.
    # (Hooks' command set is covered by the module test's pinned hookPath.)
    # systemctl and timedatectl are deliberately absent: they must come from the
    # host's own systemd, not a pinned one that could outrank it.
    wrapPATH=$(grep -oE "/nix/store/[^'\"]*/bin" ${package}/bin/migrant | sort -u | paste -sd:)
    missing=""
    for c in virsh virt-install qemu-img ip wg ssh ssh-keygen xorriso curl \
             ansible-playbook iptables ip6tables nft find mkfs.ext4 debugfs \
             mount umount findmnt mountpoint realpath awk grep sed; do
      PATH="$wrapPATH" command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    if [ -n "$missing" ]; then
      echo "FAIL: runtimeDeps does not provide:$missing" >&2
      echo "add the providing package to runtimeDeps in nix/package.nix" >&2
      exit 1
    fi
    touch $out
  '';

  # An nftables host is the one configuration where libvirt's own default picks
  # the backend migrant cannot work with: virtualisation.libvirtd.firewallBackend
  # defaults to "nftables" when networking.nftables.enable is set, and
  # libvirtd-config.service copies its generated network.conf over the file on
  # every start. Without the module's override there is no LIBVIRT_INP and every
  # isolated VM aborts at start — which the default-firewall test cannot show,
  # because nixpkgs generates "iptables" there regardless of what we do.
  module-nftables-host = pkgs.testers.nixosTest {
    name = "migrant-module-nftables-host";
    nodes.host = {
      imports = [ module ];
      virtualisation.migrant.enable = true;
      virtualisation.migrant.package = package;
      networking.nftables.enable = true;
      # For the assertions only: an nftables host has no iptables on PATH. The
      # hooks get theirs from the module's hookPath either way.
      environment.systemPackages = [ pkgs.iptables ];
    };
    testScript = ''
      host.wait_for_unit("libvirtd.service")
      host.wait_for_unit("migrant-network.service")
      host.succeed("grep -q 'firewall_backend = \"iptables\"' /var/lib/libvirt/network.conf")
      host.succeed("iptables -S INPUT | grep -q LIBVIRT_INP")
      # The chain must carry libvirt's DHCP/DNS accepts, not merely exist: the
      # hook appends its per-VM REJECT below them and relies on them landing first.
      host.succeed("iptables -S LIBVIRT_INP | grep -q 'dport 67 -j ACCEPT'")
      host.succeed("ip6tables -S INPUT | grep -q LIBVIRT_INP")
      host.succeed("test $(cat /proc/sys/net/bridge/bridge-nf-call-iptables) = 1")
      host.succeed("test $(cat /proc/sys/net/bridge/bridge-nf-call-ip6tables) = 1")
    '';
  };

  module = pkgs.testers.nixosTest {
    name = "migrant-module";
    nodes.host =
      { lib, ... }:
      {
        imports = [ module ];
        virtualisation.migrant.enable = true;
        virtualisation.migrant.users = [ "tester" ];
        virtualisation.migrant.package = package;
        # No explicit extraGroups: membership must come from the module's
        # users.groups.libvirt.members, so a broken impl is detectable.
        users.users.tester = {
          isNormalUser = true;
        };
        # Force default rp_filter=1 so the network hook flipping virbr-migrant
        # to 0 is an unambiguous, non-inherited side effect (proves it ran).
        boot.kernel.sysctl."net.ipv4.conf.default.rp_filter" = lib.mkForce 1;
        # wireguard: WG teardown test creates a wg interface. loop: loop-hook
        # test mounts a shared-folder image via mount -o loop.
        boot.kernelModules = [
          "wireguard"
          "loop"
        ];
        # Tripwire: any sudo call during the doctor makes the test fail.
        security.sudo.enable = lib.mkForce false;
        security.sudo-rs.enable = lib.mkForce false;
        # virt-install (what `migrant up` uses to create the domain) for the
        # connectivity assertion below — the virsh-only tests don't cover it.
        environment.systemPackages = [ pkgs.virt-manager ];
      };
    testScript = ''
      host.wait_for_unit("libvirtd.service")
      host.wait_for_unit("migrant-network.service")
      # module membership impl (not test-injected) put tester in libvirt:
      host.succeed("id -nG tester | grep -qw libvirt")
      # perms
      host.succeed("test $(stat -c '%a' /etc/migrant) = 3770")
      host.succeed("test $(stat -c '%G' /etc/migrant) = libvirt")
      host.succeed("test $(stat -c '%G' /var/lib/libvirt/images) = libvirt")
      host.succeed("su - tester -c 'test -w /var/lib/libvirt/images'")
      # Bridged traffic must reach ip(6)tables or every -m physdev rule the hook
      # installs matches nothing; the hook aborts the domain rather than start a
      # VM whose isolation is inert.
      host.succeed("test $(cat /proc/sys/net/bridge/bridge-nf-call-iptables) = 1")
      host.succeed("test $(cat /proc/sys/net/bridge/bridge-nf-call-ip6tables) = 1")
      # The hook positions its INPUT jump relative to LIBVIRT_INP, which only
      # libvirt's iptables backend creates. Assert both the pinned setting and
      # the chain it is pinned for — the setting alone would not prove libvirt
      # honoured it.
      host.succeed("grep -q 'firewall_backend = \"iptables\"' /var/lib/libvirt/network.conf")
      # Both families: the hook returns 7 if either INPUT lacks the chain, and
      # libvirt only builds the v6 one because network.xml declares a ULA.
      host.succeed("iptables -S INPUT | grep -q LIBVIRT_INP")
      host.succeed("ip6tables -S INPUT | grep -q LIBVIRT_INP")
      # network active + carries the IPv6 (NAT66) ULA subnet
      host.succeed("virsh net-list --name | grep -qx migrant")
      host.succeed("virsh net-dumpxml migrant | grep -q fdca:6d16:2b1a")
      # virt-install (what `migrant up` uses) must connect to qemu:///system — it
      # falls back from the modular virtqemud-sock to the monolithic libvirt-sock.
      host.succeed("virt-install --connect qemu:///system --name probe --memory 128 --disk none --import --os-variant archlinux --dry-run")
      # hooks are dispatched from /var/lib/libvirt/hooks on NixOS
      host.succeed("test -x /var/lib/libvirt/hooks/qemu.d/migrant")
      host.succeed("test -x /var/lib/libvirt/hooks/qemu.d/migrant-loop")
      host.succeed("test -x /var/lib/libvirt/hooks/network.d/migrant")
      # Nothing of ours belongs in /etc/libvirt: migrant honours LIBVIRT_CONF_DIR
      # now, so the compat placeholder that used to satisfy
      # ensure_shared_folder_images() is gone and must not come back.
      host.fail("test -e /etc/libvirt/hooks/qemu.d/migrant-loop")
      # REAL hook invocation: default rp_filter is 1, so a fresh virbr-migrant
      # inherits it; only the network hook flips it to 0 when libvirt dispatches
      # the hook on net-start -> proves dispatch + wrapper PATH (sysctl).
      host.succeed("virsh net-destroy migrant; virsh net-start migrant")
      host.wait_until_succeeds("test $(cat /proc/sys/net/ipv4/conf/virbr-migrant/rp_filter) = 0", timeout=30)
      # Reverse-path filtering must be loose: strict drops the unmarked replies
      # coming back down a VM's fwmark-routed WireGuard tunnel.
      host.succeed("iptables -t mangle -S nixos-fw-rpfilter | grep -q -- --loose")
      # Teardown: drive the qemu hook and assert rules are created on start
      # and removed on release.
      print(host.succeed("${teardownTest}"))
      # Additional teardown paths: WireGuard, NAT66, host-access rules, loop hook.
      print(host.succeed("${wgTeardownTest}"))
      print(host.succeed("${nat66TeardownTest}"))
      print(host.succeed("${hostAccessTeardownTest}"))
      print(host.succeed("${loopHookTest}"))
      # Optional-feature coverage: opt-out isolation, and virtiofs shared folders.
      print(host.succeed("${noIsolationTest}"))
      print(host.succeed("${virtiofsTest}"))
      # Lifecycle command teardown: migrant destroy fires pre/post-down hooks,
      # tears down a real (TCG) domain, and cleans rules + managed config.
      print(host.succeed("${lifecycleTest}"))
      # Doctor passes as an unprivileged user; KVM absence is a WARNING so exit
      # is 0 even under a non-KVM builder, and no sudo exists to be called.
      print(host.succeed("su - tester -c 'migrant-doctor'"))
      host.fail("command -v sudo")
      # The doctor must report what is actually configured, not merely exit 0.
      # A silently-failing extraction (the original used a variable-width PCRE
      # lookbehind, which makes grep -oP exit 2 on every host) returns the
      # default string for every input, and no exit-code assertion catches it.
      # nixpkgs builds libvirt with --sysconfdir=/var/lib, so this is the path
      # that matters here, not /etc/libvirt.
      # Anything but iptables is fatal, so these runs exit 78 — execute(), not
      # succeed(). Redirect rather than pipe: grep -q exits at the first match,
      # and the doctor then dies on EPIPE writing its remaining rows, which
      # pipefail reports as a failure even though the match succeeded.
      conf = "/var/lib/libvirt/network.conf"
      host.succeed(f"test -d $(dirname {conf})")
      for content, expected in [
          ('firewall_backend = "nftables"', "nftables \\[ERROR\\]"),
          # whitespace variants libvirt or an admin may write
          ('  firewall_backend="iptables"', "iptables"),
          ('firewall_backend\t=\t"nftables"', "nftables \\[ERROR\\]"),
          # a commented-out setting is not a setting
          ('# firewall_backend = "iptables"', "default .*\\[ERROR\\]"),
      ]:
          host.succeed(f"printf '%s\\n' '{content}' > {conf}")
          host.execute("su - tester -c migrant-doctor > /tmp/doctor.out")
          host.succeed(f"grep -Eq '^firewall backend: +{expected}' /tmp/doctor.out")
      # absent file reads as the default, which is not what the hook needs either
      host.succeed(f"rm -f {conf}")
      host.execute("su - tester -c migrant-doctor > /tmp/doctor.out")
      host.succeed("grep -Eq '^firewall backend: +default .*\\[ERROR\\]' /tmp/doctor.out")
      # The doctor must fail, not merely annotate: a wrong backend means no VM
      # can start, and `migrant setup` exiting 0 would hide that.
      host.fail("su - tester -c migrant-doctor > /tmp/doctor.out")
      # Restore what the module declares, so the handoff assertions below see a
      # healthy host rather than the state this table left behind.
      host.succeed(f"printf '%s\\n' 'firewall_backend = \"iptables\"' > {conf}")
      # `migrant setup` must hand off to the doctor rather than attempt
      # imperative setup. Assert the doctor's own output, not just the exit
      # code: a setup that silently did nothing would also exit 0.
      host.succeed("su - tester -c 'migrant setup' > /tmp/setup.out")
      host.succeed("grep -q 'managed by the migrant NixOS module' /tmp/setup.out")
      host.succeed("grep -q 'prerequisites satisfied' /tmp/setup.out")
    '';
  };
}
