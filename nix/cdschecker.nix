# CDSChecker — the UCI PLRG model checker for C11/C++11 atomics.
#
# NOT in nixpkgs (checked against this flake's pin). Upstream is
# <http://plrg.ics.uci.edu/software_page/42-2/>; the git repo it points at
# (git://demsky.eecs.uci.edu/model-checker.git) is not reachable, so the
# author's GitHub mirror `bdemsky/cdschecker` is used.
#
# CDSChecker is a SHARED LIBRARY, not a driver binary: it re-implements the C11
# atomics and the `<threads.h>` thread API, supplies its own `main`, and calls
# the program's `user_main`. So a test is COMPILED against it and then simply
# run. This derivation therefore ships:
#
#   * $out/lib/libmodel.so                        — the model itself
#   * $out/share/cdschecker/include               — its replacement headers
#   * $out/bin/cdschecker-cc                      — cc wrapper with the
#                                                   include/link/rpath flags applied
#   * $out/bin/cdschecker                         — run an already-built test binary
#
# The headers are deliberately NOT in $out/include. `mkShell` puts every input's
# include directory on the compiler search path with -isystem, and CDSChecker
# ships REPLACEMENT <stdatomic.h>, <threads.h>, <assert.h> and <stdio.h>. With
# them in $out/include, merely having cdschecker in the dev shell silently
# redirects every ordinary `cc` in the repo — `just verify-core` fails to link
# with "undefined reference to model_write_action", because the shipped C11 core
# got CDSChecker's atomics instead of the system's. Only cdschecker-cc puts them
# on the search path, and only for programs meant to be model-checked.
#
# CONSEQUENCE FOR THIS REPO, stated so it is not discovered later as a surprise:
# a program checked by CDSChecker must use ITS `thrd_create`/`thrd_join` and ITS
# `<stdatomic.h>`, and must name its entry point `user_main`. The shipped
# `verification/core/*.c` use POSIX threads and the system `<stdatomic.h>`, so
# they run under GenMC and Nidhugg unmodified but need a ported harness here.
# Those ports live in `verification/cdschecker/`, driven by `just
# verify-cdschecker`; three of the four cases run, and the fourth exposes an
# upstream abort documented in that runner.
#
# The 2014-era sources do not compile under a 2025 g++ default of `-std=gnu++17`
# (`throw(std::bad_alloc)` dynamic exception specifications were removed in
# C++17). The single patch below pins the language level instead of editing the
# sources, which keeps the checked model bit-for-bit upstream.
{
  lib,
  stdenv,
  fetchFromGitHub,
}:

stdenv.mkDerivation {
  pname = "cdschecker";
  version = "0-unstable-2020-06-30";

  src = fetchFromGitHub {
    owner = "bdemsky";
    repo = "cdschecker";
    rev = "3de23e75414a62742ffbae71e611968aef678b75";
    hash = "sha256-UYcru179+fi0BqVmB5b348dLUurv8TIx/c0VbJKHSYc=";
  };

  postPatch = ''
    substituteInPlace common.mk \
      --replace-fail 'CPPFLAGS += -Wall -O3 -g' 'CPPFLAGS += -Wall -O3 -g -std=gnu++11'
  '';

  # Only the model library: `make all` also builds the bundled tests and runs
  # a perl Markdown script for README.html, neither of which belongs in $out.
  buildPhase = ''
    runHook preBuild
    make -j$NIX_BUILD_CORES libmodel.so
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/share/cdschecker/include $out/bin
    cp libmodel.so $out/lib/
    cp -r include/. $out/share/cdschecker/include/

    cat > $out/bin/cdschecker-cc <<EOF
    #!${stdenv.shell}
    # Compile a CDSChecker test. The program must define user_main() and use
    # CDSChecker's <threads.h>/<stdatomic.h> (which is why -I comes FIRST).
    exec "\''${CC:-cc}" -I$out/share/cdschecker/include "\$@" -L$out/lib -lmodel -Wl,-rpath,$out/lib
    EOF

    cat > $out/bin/cdschecker <<EOF
    #!${stdenv.shell}
    # Run a binary built with cdschecker-cc. All further args are CDSChecker's
    # own options (-m, -y, -v ...), which its main() parses.
    if [ \$# -lt 1 ]; then
      echo "usage: cdschecker <test-binary> [cdschecker options]" >&2
      exit 2
    fi
    bin="\$1"; shift
    exec "\$bin" "\$@"
    EOF

    chmod +x $out/bin/cdschecker-cc $out/bin/cdschecker

    runHook postInstall
  '';

  meta = {
    description = "Model checker for C11/C++11 atomics (UCI PLRG)";
    homepage = "http://plrg.ics.uci.edu/software_page/42-2/";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
  };
}
