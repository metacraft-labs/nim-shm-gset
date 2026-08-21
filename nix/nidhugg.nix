# Nidhugg — stateless model checker for C/pthreads programs, working on LLVM IR.
#
# NOT in nixpkgs (checked against this flake's pin). The design spec §4.5(a)
# names GenMC / CDSChecker / Nidhugg as alternatives; Nidhugg is packaged here
# as the SECOND, independent implementation, because a single model checker
# agreeing with itself is not corroboration.
#
# LLVM VERSION, and why it is NOT the same one GenMC uses. Nidhugg's value here
# is its ARM memory model: it can run the real C11 core under ARMv8 semantics,
# which is the §4.5 ARM64 arm that qemu-user cannot deliver. But:
#
#     Error: Memory model ARM is not supported for LLVM >= 16;
#            consider configuring Nidhugg with an earlier LLVM
#
# so an LLVM-19 build gives only --sc/--tso/--pso and the ARM leg is lost. The
# caller therefore passes an llvmPackages set built from an older, separately
# pinned nixpkgs (LLVM 15) — see flake.nix. The version is still PINNED; it is
# simply pinned to a different revision than the rest of the toolchain.
{
  lib,
  stdenv,
  fetchFromGitHub,
  autoreconfHook,
  llvmPackages,
  boost,
  libffi,
  zlib,
  ncurses,
  libxml2,
  python3,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "nidhugg";
  version = "0.4-unstable-2026-04-01";

  src = fetchFromGitHub {
    owner = "nidhugg";
    repo = "nidhugg";
    rev = "0aea4d237eefe492f09df8e23a54cbeba69c42de";
    hash = "sha256-rsi4bqYQNjBTtYztf9WYz00EMmElmVsMK9haBhXf9k4=";
  };

  nativeBuildInputs = [
    autoreconfHook
    llvmPackages.llvm.dev
    python3
  ];

  buildInputs = [
    llvmPackages.llvm
    boost
    libffi
    zlib
    ncurses
    libxml2
  ];

  # nixpkgs splits boost into `dev` (headers) and `out` (libraries); the
  # ax_boost_* autoconf macros assume one prefix and derive libdir from the
  # header prefix, so the unit-test-framework link probe fails without this.
  configureFlags = [
    "--with-llvm=${llvmPackages.llvm.dev}"
    "--with-boost=${boost.dev}"
    "--with-boost-libdir=${boost.out}/lib"

    # `nidhuggc` shells out to clang to lower C/C++ to LLVM IR. Bake in the
    # clang that matches the LLVM nidhugg itself links against; without this
    # configure aborts, and a PATH lookup would reintroduce the unpinned-tool
    # problem this flake exists to remove.
    "--with-clang=${llvmPackages.clang}/bin/clang"
    "--with-clangxx=${llvmPackages.clang}/bin/clang++"
  ];

  doCheck = false;

  meta = {
    description = "Stateless model checker for C/pthreads programs under TSO/PSO/POWER/ARM";
    homepage = "https://github.com/nidhugg/nidhugg";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
    mainProgram = "nidhugg";
  };
})
