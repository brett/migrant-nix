{
  description = "NixOS packaging for migrant — secure, ephemeral libvirt/QEMU VMs for coding agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Upstream is not a flake; flake.lock is the version pin. Bump with
    # `nix flake update migrant && nix flake check` — see README.
    migrant = {
      url = "github:pigmonkey/migrant";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      migrant,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      doctor = pkgs.callPackage ./nix/doctor.nix { };
      migrantPkg = pkgs.callPackage ./nix/package.nix {
        src = migrant;
        inherit doctor;
      };

      # A NixOS system with the module enabled, booted directly in QEMU with
      # nested KVM so a real agent VM can run inside it. migrantSrc is passed
      # through for tools/netcheck.py, which lives in the migrant repo.
      testVm =
        extraModules:
        (nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs.migrantSrc = migrant;
          modules = [
            "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
            self.nixosModules.default
            ./checks/vm/host.nix
          ]
          ++ extraModules;
        }).config.system.build.vm;
    in
    {
      packages.${system} = {
        migrant = migrantPkg;
        default = migrantPkg;
        inherit doctor;

        # `nix run '.#test-vm'` — a disposable NixOS host to poke at by hand.
        test-vm = testVm [ ];

        # `nix run '.#test-vm-check'` — the same VM with a self-check that runs
        # the whole flow (doctor -> agent boot -> isolation asserts) and reports
        # PASS/FAIL via the shared dir. One-command end-to-end; needs KVM plus
        # nested virt, and takes a few minutes under double-nesting.
        test-vm-check =
          let
            vm = testVm [ ./checks/vm/selfcheck.nix ];
          in
          pkgs.writeShellScriptBin "migrant-test-vm-check" ''
            set -u
            d=$(mktemp -d)
            export SHARED_DIR="$d" NIX_DISK_IMAGE="$d/disk.qcow2"
            cd "$d"   # keep the VM's swtpm state etc. in the temp dir, not the caller's CWD
            echo "Running migrant NixOS self-check (boots a real agent VM under nested KVM; a few minutes)..."
            timeout 1500 ${vm}/bin/run-migrant-test-vm </dev/null >"$d/console.log" 2>&1 || true
            res=$(cat "$d/result" 2>/dev/null || echo NO-RESULT)
            echo
            if [ "$res" = PASS ]; then
              echo "migrant NixOS self-check: PASS"
              rm -rf "$d"
            else
              echo "migrant NixOS self-check: $res"
              echo "--- console tail ---"
              tail -60 "$d/console.log"
              exit 1
            fi
          '';
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          shellcheck
          nixfmt
          nix-update
        ];
      };

      nixosModules.default = import ./nix/module.nix self;

      checks.${system} = import ./checks {
        inherit pkgs;
        module = self.nixosModules.default;
        package = migrantPkg;
      };
    };
}
