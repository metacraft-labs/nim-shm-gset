# herd7 / litmus7 / diy7 — the herdtools7 memory-model toolsuite.
#
# NOT in nixpkgs (checked against this flake's pin: no `herdtools7`, no `herd7`,
# and no `ocamlPackages.herdtools7`), so nim-shm-gset packages it here. It is
# what `verification/litmus/*.litmus` needs; before this derivation those tests
# were authored-but-never-run.
#
# Build shape: plain dune, driven through upstream's Makefile so that
# `version-gen.sh` bakes the right `libdir` (PREFIX/share/herdtools7) into
# Version.ml — herd7 resolves its `.cat` memory models relative to that path, so
# PREFIX must be $out at BUILD time, not just at install time.
{
  lib,
  stdenv,
  fetchFromGitHub,
  ocamlPackages,
  dune_3,
  which,
}:

stdenv.mkDerivation rec {
  pname = "herdtools7";
  version = "7.58";

  src = fetchFromGitHub {
    owner = "herd";
    repo = "herdtools7";
    rev = version;
    hash = "sha256-0+tyzuEPji/mCsN6ez4C+iJz5IroV3zAjVsbgG6lPJo=";
  };

  nativeBuildInputs = [
    # `make check-deps` probes for its tools with `which`.
    which
    ocamlPackages.ocaml
    ocamlPackages.findlib
    ocamlPackages.menhir
    dune_3
  ];

  buildInputs = [
    ocamlPackages.menhirLib
    ocamlPackages.zarith
  ];

  strictDeps = true;

  # Upstream's `defs.sh` shells out to `git rev-parse` for the revision and
  # falls back to the literal "exported" when git is absent, which is exactly
  # the sandbox situation — no patching needed, the version still comes from
  # VERSION.txt. (`herd7 -version` therefore prints "7.58, Rev: exported".)
  #
  # dune wants a writable HOME for its cache and warns loudly without one.
  preBuild = ''
    export HOME=$TMPDIR
  '';

  buildPhase = ''
    runHook preBuild
    make PREFIX=$out all
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    make PREFIX=$out install
    runHook postInstall
  '';

  doCheck = false; # upstream `make test` is a multi-thousand-litmus regression run

  meta = {
    description = "Memory-model tool suite (herd7, litmus7, diy7) from the herd project";
    homepage = "https://github.com/herd/herdtools7";
    license = lib.licenses.cecill-b;
    platforms = lib.platforms.unix;
    mainProgram = "herd7";
  };
}
