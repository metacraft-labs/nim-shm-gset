# GenMC — stateless model checker for C11 programs under weak memory.
#
# NOT in nixpkgs (checked against this flake's pin). This is the tool the design
# spec §4.5(a) names first for "stateless model checking under weak memory of
# the extracted C11 atomics core", and it is the ONLY artifact in this repo that
# can express the `m6` gap: TLA+ models `PAttach` atomically, so it cannot even
# state "a producer registered but missed the seal"; GenMC runs the real C11
# core, so it can.
#
# LLVM coupling: GenMC interprets LLVM IR. Upstream 0.17.0 supports LLVM 15-20;
# the pin below picks ONE and holds it, because the tool must be built against
# exactly the LLVM whose bitcode format it parses, and the `clang` it shells out
# to at runtime must be the same major version. Both are baked into the binary
# (`lli_config.h`'s CLANGPATH), so nothing is resolved from the caller's PATH.
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  llvmPackages_19,
  libffi,
  zlib,
  libxml2,
  ncurses,
}:

let
  llvmPackages = llvmPackages_19;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "genmc";
  version = "0.17.0";

  src = fetchFromGitHub {
    owner = "MPI-SWS";
    repo = "genmc";
    rev = "v${finalAttrs.version}";
    hash = "sha256-2lLh1w/Qd7RcmVIx1Edsk4rxXxg00Tv/JTmpin8Rqbs=";
  };

  nativeBuildInputs = [ cmake ];

  buildInputs = [
    llvmPackages.llvm
    llvmPackages.llvm.dev
    llvmPackages.clang
    libffi
    zlib
    libxml2
    ncurses
  ];

  # Upstream looks for `clang` and `llvm-config` ONLY inside
  # ${LLVM_TOOLS_BINARY_DIR}, which works on distros that ship llvm, llvm-dev
  # and clang under one prefix. nixpkgs splits all three (clang is its own
  # derivation, llvm-config lives in llvm's `dev` output), so point both lookups
  # at the exact store paths rather than relaxing them to a PATH search — a PATH
  # search would silently bake in whatever clang the builder happened to have,
  # which is the same unpinned-tool defect this flake exists to remove.
  postPatch = ''
    substituteInPlace CMakeLists.txt \
      --replace-fail \
      'find_program(CLANGPATH clang PATHS ''${LLVM_TOOLS_BINARY_DIR} NO_CACHE NO_DEFAULT_PATH REQUIRED)' \
      'set(CLANGPATH "${llvmPackages.clang}/bin/clang")'
    substituteInPlace CMakeLists.txt \
      --replace-fail \
      'find_program(LLVM_CONFIG_PATH llvm-config PATHS ''${LLVM_TOOLS_BINARY_DIR} NO_CACHE NO_DEFAULT_PATH REQUIRED)' \
      'set(LLVM_CONFIG_PATH "${llvmPackages.llvm.dev}/bin/llvm-config")'
  '';

  cmakeFlags = [
    (lib.cmakeFeature "CMAKE_BUILD_TYPE" "RelWithDebInfo")
    (lib.cmakeFeature "CMAKE_PREFIX_PATH" "${llvmPackages.llvm.dev}/lib/cmake/llvm")

    # LOAD-BEARING. Upstream computes the runtime-header search path it bakes
    # into the binary as "${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_INCLUDEDIR}/
    # genmc/runtime", assuming INCLUDEDIR is RELATIVE. The nixpkgs cmake setup
    # hook passes it as an ABSOLUTE path, which yields a doubled, nonexistent
    # "$out/$out/include/..." — clang then silently falls back to the SYSTEM
    # <pthread.h> and every run dies with "Tried to execute an unknown external
    # function: pthread_create". Forcing it back to a relative path is what
    # makes GenMC able to check pthread programs at all.
    (lib.cmakeFeature "CMAKE_INSTALL_INCLUDEDIR" "include")
  ];

  # Upstream installs the driver as bin/genmc/genmc (the bin/genmc DIRECTORY
  # exists to avoid clashing with the genmc/ library dir at build time), which
  # leaves nothing named `genmc` on PATH. Flatten it.
  postInstall = ''
    mv $out/bin/genmc $out/bin/.genmc-bindir
    mv $out/bin/.genmc-bindir/genmc $out/bin/genmc
    rmdir $out/bin/.genmc-bindir
  '';

  doCheck = false; # upstream ctest suite is a multi-hour exhaustive run

  meta = {
    description = "Stateless model checker for C11 concurrent programs under weak memory";
    homepage = "https://plv.mpi-sws.org/genmc";
    # Dual Apache-2.0 OR MIT, with some LLVM-derived files under the LLVM
    # exception (LICENSE-APACHE, LICENSE-MIT, LLVMLICENSE in the tree).
    license = with lib.licenses; [
      asl20
      mit
    ];
    platforms = lib.platforms.linux;
    mainProgram = "genmc";
  };
})
