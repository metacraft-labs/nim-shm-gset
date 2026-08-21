{
  description = "nim-shm-gset plus the pinned formal / weak-memory verification toolchain required by design spec section 4.5";

  # PINNED, deliberately. This repo's product is verification EVIDENCE, so the
  # tools that produce it must not be resolved through the mutable system flake
  # registry (`nix shell nixpkgs#...`), which points at whatever the machine
  # happened to sync last. This revision is the one every §4.5 result currently
  # recorded in verification/README.md was produced against.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/0c88e1f2bdb93d5999019e99cb0e61e1fe2af4c5";

  # SECOND pin, for ONE package. Nidhugg refuses to even OFFER its ARM memory
  # model when built against LLVM >= 16, and the primary pin above has dropped
  # llvmPackages_14/15/16 as "unmaintained and obsolete"; this revision still
  # carries LLVM 15. It is a pin, not a registry lookup, so the reproducibility
  # property is unchanged.
  #
  # Honest footnote: this buys less than hoped. With --arm SELECTABLE, Nidhugg
  # then rejects the C11 cores anyway — its ARM/POWER trace builders do not
  # support read-modify-writes, and the cores' arena bump and slot CAS are both
  # RMWs. Nidhugg contributes --sc/--tso/--pso corroboration; the ARMv8 coverage
  # comes from herd7 (verification/litmus/arch) and GenMC/RC11. The pin is kept
  # so the ARM leg is a one-line retry when upstream lifts that restriction,
  # rather than a re-packaging job.
  inputs.nixpkgs-llvm15.url = "github:NixOS/nixpkgs/ac62194c3917d5f474c1a844b6fd6da2db95077d";

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-llvm15,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          pkgs15 = nixpkgs-llvm15.legacyPackages.${system};
          crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
        in
        {
          # Weak-memory / stateless model checkers that nixpkgs does not carry.
          herdtools7 = pkgs.callPackage ./nix/herdtools7.nix { };
          genmc = pkgs.callPackage ./nix/genmc.nix { };
          cdschecker = pkgs.callPackage ./nix/cdschecker.nix { };

          # Built entirely from the LLVM-15 pin (not just its LLVM), so boost,
          # the C++ stdlib and LLVM all come from one consistent package set.
          nidhugg = pkgs15.callPackage ./nix/nidhugg.nix {
            llvmPackages = pkgs15.llvmPackages_15;
          };

          # The aarch64 cross leg (`just verify-aarch64`). This is a PATH-only
          # environment used with `nix shell`, NOT a devShell, and that is
          # deliberate: any `nix develop` shell exports NIX_CFLAGS_COMPILE with
          # `-isystem <NATIVE glibc>/include` for its own inputs, the cross gcc
          # wrapper honours it, and the cross build then dies on
          #     fatal error: gnu/stubs-32.h: No such file or directory
          # `nix shell` only puts binaries on PATH, which is exactly what the old
          # ad-hoc `nix shell nixpkgs#pkgsCross...` invocation did — the change
          # here is that the toolchain is pinned rather than taken from the
          # machine's flake registry.
          aarch64-cross-env = pkgs.buildEnv {
            name = "nim-shm-gset-aarch64-cross-env";
            paths = [
              crossPkgs.buildPackages.gcc
              crossPkgs.glibc
              pkgs.qemu # qemu-aarch64 (user mode)
              pkgs.file # the runner reports what it produced
            ];
            ignoreCollisions = true;
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          self' = self.packages.${system};

          # Model checkers that are only expected to build on Linux.
          modelCheckers = [
            self'.herdtools7
          ]
          ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            self'.genmc
            self'.nidhugg
            self'.cdschecker
          ];
        in
        {
          # gcc15Stdenv, not the pin's default gcc14. LOAD-BEARING: `just
          # verify-core` builds the reset core with -fsanitize=thread, and
          # gcc 14's bundled TSAN runtime dies on this kernel's address-space
          # layout with
          #     FATAL: ThreadSanitizer: unexpected memory mapping 0x...
          # before running a single iteration. gcc 15's runtime handles it. The
          # workspace's ambient toolchain is also gcc 15, so this keeps the
          # flake and the ambient shell producing the same result rather than
          # the flake silently losing the TSAN leg of §4.5(g).
          default = (pkgs.mkShell.override { stdenv = pkgs.gcc15Stdenv; }) {
            name = "nim-shm-gset-verification";

            packages = [
              # Build + functional suite. Same Nim VERSION (2.2.4) the
              # workspace shell provides, from the pinned nixpkgs.
              pkgs.nim
              pkgs.just
              pkgs.pkg-config

              # §4.5(a) formal tier.
              pkgs.tlaplus # tlc, tlasany, pcal

              # §4.5(g) dynamic tier (previously ambient, now pinned too).
              pkgs.valgrind
            ]
            ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.rr
            ++ modelCheckers;

            # Only when a human is looking. `just verify-*` runs every recipe
            # line through `nix develop --command`, and an unconditional banner
            # would bury the actual verification output under six copies of
            # itself.
            shellHook = ''
              if [ -t 1 ]; then
                echo "nim-shm-gset verification shell (pinned)"
                for t in tlc herd7 genmc nidhugg cdschecker; do
                  printf '  %-11s %s\n' "$t" \
                    "$(command -v "$t" >/dev/null && echo yes || echo MISSING)"
                done
              fi
            '';
          };

        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-rfc-style);
    };
}
