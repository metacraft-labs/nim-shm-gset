#!/usr/bin/env bash
# Runner-parity gate for nim-shm-gset.
#
# WHY THIS EXISTS. This repo has TWO test runners over ONE suite — the `test`
# recipe in the Justfile and the `test` task in shm_gset.nimble — and the rule
# both files state in their own comments is that a required milestone test must
# not be reachable from one runner only. Nothing enforced it, and for months it
# was false: `tests/test_shm_gset_{transport,lf5,concurrency,threads}.nim` — 16
# cases, among them the whole §4.5 SIGKILL fault-injection battery and the LF-1
# / LF-2 lossless-capture gates — were compiled by the Justfile and by nothing
# else. `just test` reported 101 [OK] and `nimble test` 85, and the difference
# was invisible because nimble was not even installed, so the nimble task had
# only ever been REVIEWED BY READING. It was discovered, not caught. This script
# makes the next occurrence a hard failure at the first line of both runners.
#
# WHAT IT CHECKS, all of them as errors:
#   1. Same FILE SET. Every `tests/**/*.nim` compiled by one runner is compiled
#      by the other.
#   2. Same FLAG SET per file. A file built with `-d:shmGSetScheduleHooks` or
#      `-d:nimAllocStats` under one runner and without it under the other is a
#      silently WEAKER run, not a parity violation you would notice in a count
#      (both would still report the same number of [OK] lines). The two files
#      also used to disagree on `--path:tests`, which the Justfile applied to
#      every compile and the nimble task to four files only.
#   3. Same EXECUTION per file, checked SEPARATELY from the flags. `-r` is the
#      difference between building a test and RUNNING it, and it is deliberately
#      NOT part of the flag set compared in (2) — see the next block — so it
#      gets its own rule, in two parts:
#        3a. ASYMMETRY is always fatal. A file one runner runs and the other
#            merely builds is the silently-weaker-run class this gate exists
#            for: the counts still match, both runners still "compile the same
#            files with identical flags", and one of them stopped executing the
#            cases.
#        3b. A registered file that NEITHER runner runs is fatal too, unless it
#            lives in `tests/helpers/`. Dropping `-r` from BOTH runners is the
#            same defeat with one more keystroke, and symmetry alone would call
#            it parity.
#   4. Every `.nim` file under `tests/` is ACCOUNTED FOR. A test file wired into
#      neither runner passes checks 1–3 vacuously.
#
# WHY `-r` IS NOT JUST ANOTHER COMPARED FLAG. `tests/helpers/v2_producer.nim` is
# a rev-2 PEER BINARY: `test_shm_gset_version_skew.nim` execs it as a separate
# process, so it is legitimately built and not run, by both runners, on purpose.
# Folding `-r` into the sorted flag set of (2) would compare it symmetrically
# and so would still accept it — but it would ALSO accept `-r` being dropped
# from both runners' `test_shm_gset_lf5.nim` line, because that too is
# symmetric. Execution is a property of a file (is this suite RUN?), not a
# spelling difference between two recipes, so it is modelled as one.
#
# SCOPE — deliberately WIDER than the file's first version, which discovered
# only `tests/test_*.nim` at depth 1. Both narrowings were reachable by
# accident, not just by malice: a suite that grows a `tests/keyed/` subdirectory,
# or a file named `soak_probe.nim`, is an ordinary thing to write, and under the
# old scope either would have been registered with neither runner and reported
# as OK. Discovery is now `tests/**/*.nim`, at ANY depth and under ANY name, and
# a file is accounted for in exactly one of three ways:
#   (a) it is REGISTERED with both runners (checks 1–3 then apply to it);
#   (b) a registered compile IMPORTS it, transitively — `tests/ac_index_model.nim`
#       is the reference-model module three registered tests import via
#       `--path:tests`. It is compiled and exercised by each of them; requiring
#       it to be a runner entry of its own would be wrong. Coverage is DERIVED
#       from the imports rather than allow-listed, so it cannot be claimed for a
#       file nothing imports — nor, in the spellings the guard check below can
#       SEE, for one whose cases hide behind `when isMainModule`, which an
#       importer does not execute. Two spellings it cannot see are listed under
#       OPEN; do not read this sentence as covering them.
#
#       An import is resolved the way the COMPILER resolves it, to the ONE path
#       it actually opens, and the exemption is granted to that path only:
#         * `<dir of the importing file>/<token>.nim` IF THAT FILE EXISTS,
#           because Nim looks beside the importer first and stops there;
#         * otherwise `tests/<token>.nim`, because both runners pass
#           `--path:tests`.
#       One candidate, never both. Offering both was a fail-OPEN hole, not a
#       harmless over-approximation: with `tests/helpers/tok.nim` AND
#       `tests/tok.nim` both on disk, `import tok` from `tests/helpers/…`
#       compiles the SIBLING and nothing at all compiles `tests/tok.nim` — asked
#       of the compiler twice, once with the sibling present (the `tests/` copy's
#       `{.error.}` never fires) and once with it removed (then it does). Under
#       the old two-candidate rule that unbuilt `tests/tok.nim` was reported as
#       covered, which is exactly the class of silent gap this gate exists for.
#       For an explicitly RELATIVE token (`./x`, `../x`) it is the first form
#       only, because Nim does not consult the search path for those at all.
#       `../` walks up: `import ../ac_index_model` from a `tests/*.nim`
#       file compiles `<repo>/ac_index_model.nim`, which is outside this gate's
#       scope, and grants `tests/ac_index_model.nim` nothing. The match used to be a path SUFFIX, which is depth-blind:
#       `import ac_index_model` in a `tests/*.nim` file also claimed
#       `tests/keyed/ac_index_model.nim`, `tests/x/y/shm_gset.nim` and
#       `tests/x/shm_gset/transport.nim` — files `nim c` refuses to open. The
#       compiler was asked: `import mymod` from `tests/t.nim`, with
#       `tests/sub/mymod.nim` on disk and `--path:tests`, fails with
#       `Error: cannot open file: mymod`. A gate whose SCOPE paragraph
#       advertises a `tests/keyed/` subdirectory cannot be blind to depth.
#       Reading a bracket group as the bare names `os` and `sets`
#       — which this did until the tokens were qualified — was the same class of
#       hole one level up: it handed a free pass to `tests/os.nim`,
#       `tests/sets.nim`, `tests/unittest.nim` and every other file named after
#       a module the suite already imports.
#
#       A `std/…` token grants nothing at all: Nim resolves it inside its own
#       standard library, so `import std/[os, sets]` does NOT compile a sibling
#       `tests/std/os.nim` (verified with the compiler: the probe fails with
#       `undeclared identifier`). Such a file is unaccounted for and must be
#       registered.
#
#       Only text Nim actually compiles counts: `#` and `#[ … ]#` comments,
#       `""" … """` long strings (a `discard """ … """` spec is prose, and prose
#       says "import"), and the indented body of EVERY conditional-compilation
#       head — any `when`, any `elif`, any `else:`, whatever the condition says
#       — are removed first.
#
#       This gate cannot EVALUATE a `when`, so it declines to derive coverage
#       from an import inside ANY of them rather than guessing. It used to skip
#       two spellings only, `when false:` and `when [not] defined(…)`, and the
#       header claimed the resulting imprecision "can only cost a file its
#       exemption … never grant one". That was FALSE, and measurably so: four
#       further heads were read as live code, and the compiler compiles none of
#       their bodies on this host —
#         * `elif defined(neverDefined):` after an unsatisfied `when`;
#         * `else:` after a `when defined(linux):` that IS satisfied;
#         * `when hostOS == "windows":`;
#         * `when compiles(<undeclared identifier>):`.
#       Each granted an exemption to a file nothing compiles. Skipping every
#       head is the only direction that fails closed, and it costs nothing here:
#       no `tests/**` file in this repo has an indented import at all.
#
#       Spelling does not help either. Nim matches keywords with the same
#       partial style-insensitivity it applies to identifiers — first character
#       case-sensitive, every later character ignoring case AND underscores — so
#       `wHen`, `w_hen`, `el_if` and `el_se` are the real keywords (each
#       measured: the body of `w_hen defined(linux):` DOES compile), and
#       `when(defined(x)):` needs no space. A literal text match on `when` was
#       evadable by four more spellings on top of the four heads above. The
#       leading word is therefore normalised before it is compared.
#
#       And a UTF-8 BOM on line 1 defeated the `^` anchor outright: Nim skips
#       the BOM, so BOM + `when defined(neverDefined):` compiles and does not
#       compile its body, while the head match saw three stray bytes and read
#       the body as live code. The BOM is stripped before anything else looks at
#       line 1;
#
#       Because the skip is unconditional, a module imported only under a
#       condition that IS satisfied here — `when defined(linux): import x` on
#       this Linux host — loses its exemption and must be registered with both
#       runners like any other. That is the fail-closed direction, on purpose;
#   (b') and a file a runner NAMES but that is not on disk is an error, because
#       every check above passes vacuously for it;
#   (c) it lives in `tests/helpers/`, the fixture directory for programs driven
#       by something other than the `test` runners (a test that compiles a
#       negative-compilation probe at runtime, the `test-valgrind` recipe). To
#       keep that from becoming a hiding place, an unregistered, unimported
#       helper must still be REFERENCED by name somewhere in the repo; an
#       orphaned one is an error.
#
# WHAT IT STILL CANNOT SEE, stated rather than implied — and this list has been
# WRONG before, in the direction that flatters the gate. It once said "two fail
# closed … two are open" while SEVERAL further fail-OPEN cases sat unmentioned:
# four conditional heads the tokeniser read as live code, the two-candidate
# import over-grant, four keyword spellings (`wHen`, `w_hen`, `el_if`, `el_se`)
# and `when(…)` that evaded the head match by text alone, the same evasion
# against the `when isMainModule` check, a UTF-8 BOM that defeated the `^`
# anchor, and this file counting as a driver of its own fixtures. All of those
# are closed and each is mutation-checked — reverting the fix reddens exactly
# the case it was written for and nothing else. Every case below has been
# MEASURED with the compiler, and the OPEN ones really are open: nothing here is
# a guarantee, and the honest reading of this list is that a further round will
# find more. It did. The last three OPEN entries below were found by
# re-attacking this version, and two of them show that the BOM fix and the
# keyword-normalisation fix landed at ONE of their two normalisation sites, not
# both. They are documented rather than patched on purpose: the answer to them
# is to stop text-matching and ask the compiler what it actually compiles.
#
# FAIL-CLOSED (a file loses an exemption it may deserve, and has to be
# registered — noisy, never silent):
#   * an import split across lines (`import`⏎`  x`) yields NO token. Measured.
#   * a bracket group split across lines (`import aaa/[`⏎`  bbb, ccc]`) yields
#     the junk token `aaa/[`, which matches no file — NOT "no token", as this
#     list used to say. Nim does compile that form (measured), so `tests/aaa/
#     bbb.nim` and `tests/aaa/ccc.nim` come back unaccounted for.
#   * `include "helpers/x.nim"`, the QUOTED spelling that carries the extension.
#     Nim opens `tests/helpers/x.nim` for it (measured: the target's `{.error.}`
#     fires), but the token keeps its `.nim`, so the candidate this gate forms
#     is `tests/helpers/x.nim.nim` and matches nothing. It is legitimate Nim
#     that this gate does NOT resolve; the note further down used to imply the
#     opposite. The two neighbouring spellings are NOT this case, and this
#     bullet used to lump them in: `include helpers/x`, without the extension,
#     opens the same file (measured) and IS resolved correctly, so it costs
#     nothing; `include helpers/x.nim` UNQUOTED is not legitimate Nim at all —
#     measured, it dies with `Error: cannot open file: helpers/x/nim`, because
#     the bare `.nim` is read as another path separator.
#   * every conditional body, including one this host really does compile
#     (`when defined(linux): import x`). Deliberate; see (b) above.
#   * a runner compile reformatted onto two lines with a `\` continuation is not
#     recognised as a compile at all, so the file drops out of that runner's
#     set — reported as file-set drift, or as unaccounted-for if BOTH runners
#     are reformatted. The required single-line shape is stated below.
#
# OPEN (a file can still be granted coverage it has not earned):
#   * `if isMainModule:` is not the guard checked in (b) — only the `when` form
#     is, in every spelling — so an import-exempt module can still hide its
#     cases behind the RUNTIME conditional. OPEN.
#   * the `tests/helpers/` driver check is a plain-text substring grep over
#     Justfile / shm_gset.nimble / tests / scripts, so (i) a very short basename
#     (`tests/helpers/e.nim` -> `e`) matches almost any file, and (ii) a mere
#     COMMENT naming the fixture counts as driving it. THIS FILE is excluded
#     from that search — a gate is not a driver, and one of its own comments
#     naming a fixture used to satisfy the rule by itself — but a comment
#     anywhere else still counts. OPEN.
#   * the import resolver assumes `--path:src --path:tests` in THAT order, which
#     is what both runners pass today and what the compiler was measured
#     against: with `tests/shadow.nim` and `src/shadow.nim` both on disk, `nim c`
#     opens the `tests/` copy, and reversing the two `--path` flags makes it open
#     the `src/` copy instead. The gate does not read the flag ORDER, so under a
#     reordered or added `--path` root it could still grant `tests/<token>.nim`
#     for a module the compiler took from elsewhere. Nothing detects that. OPEN.
#   * a `case`/`of` branch is not treated as a conditional head (only
#     `when`/`elif`/`else` are), so an import under `of` would be read. Nim does
#     not accept a module-level `import` there, which is why this is listed and
#     not closed. OPEN, on a premise about the language rather than a measurement
#     of this gate.
#   * `tests/helpers/` is an EXECUTION exemption granted by PATH, not by
#     evidence: rule 3b skips the run-by-neither check for anything under it. A
#     real suite moved there and registered with both runners, minus `-r`, is
#     built and never executed and this gate still says OK. That is the same
#     shape as the divergence it was written to catch, one `git mv` away. The
#     directory exists because `v2_producer` genuinely must be built and not
#     run; nothing distinguishes a peer binary from a parked suite. OPEN.
#   * the `when isMainModule` check does NOT strip a UTF-8 BOM, although the
#     import tokeniser does — the fix landed at one of the two sites. A module
#     whose FIRST line is BOM + `when isMainModule:` keeps its import exemption
#     while its cases still run only as main. Measured: that file compiles, its
#     guarded body prints when the module is run directly and does NOT print
#     when the module is imported, and this gate says OK; delete the three BOM
#     bytes and the same file is caught. OPEN.
#   * the same check reads the `when`/`elif` HEAD, so one level of indirection
#     hides the guard from it: `const runMain = isMainModule` followed by
#     `when runMain:` is the very same guard — measured, the body runs only as
#     main — and no head mentions `isMainModule` for the identifier scan to
#     find. Any compile-time alias does this. OPEN.
#   * a nimble `exec` nested inside a NimScript conditional is read as an
#     UNCONDITIONAL compile. The task parser strips leading whitespace before it
#     looks for `^exec `, so `when defined(neverDefinedXYZ):` wrapped around one
#     of the task's `exec` lines leaves that file in this gate's nimble set,
#     while NimScript really does skip the body (measured with `nim e`). The
#     Justfile still runs the file, the nimble task does not, and the gate
#     reports parity — the silently-weaker-run shape this file exists for,
#     arrived at from the RUNNER side rather than the import side. The Justfile
#     recipe has no equivalent: a recipe line that is not literally `nim c …`
#     drops out of its set and is reported as drift. OPEN.
#
# It is a TEXT check over the two runner definitions, deliberately: the thing
# that drifted is the two files' agreement, and that is a property of the files.
# It requires each runner to keep its compiles in the machine-readable shape
# below, and it FAILS CLOSED — a recipe or task it cannot parse (zero compiles
# found) is an error, not a pass.
#
# Shape required of the Justfile `test:` recipe:
#     nim c [-r] {{nim_flags}} [extra flags] tests/<file>.nim
# Shape required of the nimble `test` task:
#     exec "nim c [-r] " & testFlags & " [extra flags] tests/<file>.nim"
# with the flag values defined once each as `nim_flags := "..."` (Justfile) and
# `const testFlags = "..."` (nimble), on a single line.
set -euo pipefail
# Every sort and every comm in this script must agree on collation, or `comm`
# rejects its own inputs as unsorted.
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JUSTFILE="$REPO_ROOT/Justfile"
NIMBLE="$REPO_ROOT/shm_gset.nimble"
# This file's own absolute path. The `tests/helpers/` driver search below greps
# `scripts/`, so without this THIS FILE counts as a driver: naming a fixture in
# one of the comments here — which discussing the gate naturally does — would
# satisfy the "something drives this fixture" rule all by itself. The gate is
# not a driver of anything.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

fail() {
  echo "check-runner-parity: $*" >&2
  exit 1
}

[ -f "$JUSTFILE" ] || fail "no Justfile at $JUSTFILE"
[ -f "$NIMBLE" ] || fail "no nimble file at $NIMBLE"

# --- the two single-definition flag strings -------------------------------
just_flags="$(sed -n 's/^nim_flags[[:space:]]*:=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$JUSTFILE")"
[ -n "$just_flags" ] || fail "could not read \`nim_flags := \"...\"\` from the Justfile"
nimble_flags="$(sed -n 's/^const testFlags[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$NIMBLE")"
[ -n "$nimble_flags" ] || fail "could not read \`const testFlags = \"...\"\` from $NIMBLE"

# --- normalise one compile command into "<file>\t<sorted flags>\t<run>" ----
# Drops `nim`, `c` and `-o:<path>`; the target is the `tests/**/*.nim` argument.
# Flags are sorted so argument ORDER is not treated as a difference. `-r` is
# pulled OUT of the flag set into its own `run` column — it is not a spelling
# difference, it is whether the suite executes (see the header).
emit_entry() {
  local cmd="$1"
  local file="" run=0 flags=() tok
  for tok in $cmd; do
    case "$tok" in
      nim | c) ;;
      -r | --run) run=1 ;;
      -o:*) ;;
      tests/*.nim) file="$tok" ;;
      *) flags+=("$tok") ;;
    esac
  done
  [ -n "$file" ] || return 0 # a compile with no tests/*.nim target is not ours
  local sorted
  sorted="$(printf '%s\n' "${flags[@]:-}" | LC_ALL=C sort | tr '\n' ' ')"
  printf '%s\t%s\t%s\n' "$file" "${sorted% }" "$run"
}

# --- extract the Justfile `test:` recipe ----------------------------------
just_body="$(awk '
  /^test:([[:space:]]|$)/ { inrec = 1; next }   # `test:` with or without deps
  inrec && /^[^[:space:]]/ && !/^[[:space:]]*$/ { inrec = 0 }
  inrec { print }
' "$JUSTFILE")"
[ -n "$just_body" ] || fail "could not locate the \`test:\` recipe in the Justfile"

just_entries="$(
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}" # ltrim
    case "$line" in
      \#* | '') continue ;;
      nim\ c\ *) ;;
      *) continue ;;
    esac
    line="${line//\{\{nim_flags\}\}/$just_flags}"
    emit_entry "$line"
  done <<<"$just_body"
)"

# --- extract the nimble `test` task ---------------------------------------
# Joins `&`-continued string expressions into one logical line, substitutes the
# `testFlags` identifier as a quoted literal, then glues the literals together.
nimble_entries="$(
  awk -v flags="$nimble_flags" '
    /^task test,/ { intask = 1; next }
    intask && /^task / { intask = 0 }
    !intask { next }
    { line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/ || line == "") { if (buf == "") next }
      if (buf == "" && line !~ /^exec /) next
      buf = buf line
      if (line ~ /&[[:space:]]*$/) next   # continued onto the next line
      print buf
      buf = ""
    }
  ' "$NIMBLE" |
    while IFS= read -r expr; do
      expr="${expr#exec }"
      # `testFlags` -> its value, as a literal, then collapse `" & "` glue.
      expr="${expr//testFlags/\"$nimble_flags\"}"
      expr="$(printf '%s' "$expr" | sed 's/"[[:space:]]*&[[:space:]]*"//g')"
      expr="${expr#\"}"
      expr="${expr%\"}"
      case "$expr" in
        nim\ c\ *) emit_entry "$expr" ;;
        *) continue ;;
      esac
    done
)"

# --- fail closed on an unparseable runner ---------------------------------
just_n="$(printf '%s' "$just_entries" | grep -c . || true)"
nimble_n="$(printf '%s' "$nimble_entries" | grep -c . || true)"
[ "$just_n" -gt 0 ] || fail "parsed ZERO compiles out of the Justfile \`test:\` recipe — the recipe's shape changed and this gate would pass vacuously"
[ "$nimble_n" -gt 0 ] || fail "parsed ZERO compiles out of the nimble \`test\` task — the task's shape changed and this gate would pass vacuously"

just_list="$(printf '%s\n' "$just_entries" | cut -f1,2 | LC_ALL=C sort)"
nimble_list="$(printf '%s\n' "$nimble_entries" | cut -f1,2 | LC_ALL=C sort)"

rc=0

# --- 1 + 2: file set and per-file flag set --------------------------------
if [ "$just_list" != "$nimble_list" ]; then
  rc=1
  echo "check-runner-parity: the two test runners DISAGREE." >&2
  echo "  Justfile \`test:\` recipe vs. shm_gset.nimble \`test\` task." >&2
  while IFS=$'\t' read -r f fl; do
    [ -n "$f" ] || continue
    echo "  only in the Justfile:  $f   [$fl]" >&2
  done < <(comm -23 <(printf '%s\n' "$just_list") <(printf '%s\n' "$nimble_list"))
  while IFS=$'\t' read -r f fl; do
    [ -n "$f" ] || continue
    echo "  only in the nimble task: $f   [$fl]" >&2
  done < <(comm -13 <(printf '%s\n' "$just_list") <(printf '%s\n' "$nimble_list"))
  echo "  (a file listed on BOTH sides above differs in its FLAGS, not its presence)" >&2
fi

registered="$(printf '%s\n%s\n' "$just_list" "$nimble_list" | cut -f1 | grep . | LC_ALL=C sort -u || true)"

# --- 3: COMPILED is not RUN -----------------------------------------------
# `just_run[file]` / `nimble_run[file]` are 1 when that runner passes `-r`.
declare -A just_run=() nimble_run=()
while IFS=$'\t' read -r f _fl r; do
  [ -n "$f" ] || continue
  # A file compiled twice by one runner counts as RUN if any of its compiles
  # runs it; the build-then-run pair is a legitimate shape.
  [ "$r" = "1" ] && just_run["$f"]=1 || just_run["$f"]="${just_run[$f]:-0}"
done < <(printf '%s\n' "$just_entries")
while IFS=$'\t' read -r f _fl r; do
  [ -n "$f" ] || continue
  [ "$r" = "1" ] && nimble_run["$f"]=1 || nimble_run["$f"]="${nimble_run[$f]:-0}"
done < <(printf '%s\n' "$nimble_entries")

while IFS= read -r f; do
  [ -n "$f" ] || continue
  jr="${just_run[$f]:-0}"
  nr="${nimble_run[$f]:-0}"
  if [ "$jr" != "$nr" ]; then
    rc=1
    if [ "$jr" = "1" ]; then
      only=Justfile; other="the nimble \`test\` task"
    else
      only="nimble \`test\` task"; other="the Justfile \`test:\` recipe"
    fi
    echo "check-runner-parity: $f is RUN by the $only but only BUILT by $other." >&2
    echo "  A missing \`-r\` compiles the file and never executes a single case, while" >&2
    echo "  the file set and the flag sets still match. Add \`-r\` on both sides." >&2
  elif [ "$jr" = "0" ]; then
    case "$f" in
      tests/helpers/*) ;; # fixture programs are built on purpose; see the header
      *)
        rc=1
        echo "check-runner-parity: $f is compiled by BOTH runners and RUN by NEITHER." >&2
        echo "  Without \`-r\` this file's cases never execute. Add \`-r\` on both sides," >&2
        echo "  or move it to tests/helpers/ if it is a fixture program rather than a suite." >&2
        ;;
    esac
  fi
done < <(printf '%s\n' "$registered")

# --- 4a: every registered file EXISTS -------------------------------------
# A runner line naming a file that is not on disk is a broken runner, and the
# checks above are all satisfied by it vacuously — both runners "compile" it
# with identical flags and both "run" it. `nim c` would fail on the next run,
# so this only shortens the feedback loop, but it also stops a deleted file
# from silently propping up another file's import exemption.
missing_registered=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$REPO_ROOT/$f" ] || missing_registered="${missing_registered}${f}"$'\n'
done < <(printf '%s\n' "$registered")
if [ -n "${missing_registered//[$'\n']/}" ]; then
  rc=1
  echo "check-runner-parity: file(s) registered with a runner but NOT on disk:" >&2
  printf '%s' "$missing_registered" | grep . | sed 's/^/  /' >&2
  echo "  Remove the compile line, or restore the file." >&2
fi

# --- 4: every .nim under tests/ is accounted for --------------------------
# `-L` so a symlinked file or subdirectory under tests/ is discovered too,
# rather than being an unlisted way out of the scope.
on_disk="$(cd "$REPO_ROOT" && find -L tests -type f -name '*.nim' -printf '%p\n' | LC_ALL=C sort)"
[ -n "$on_disk" ] || fail "no tests/**/*.nim found — run this from the repo"
all_nim="$on_disk"

# --- the module names one file imports, as Nim would read them -------------
# One token per module, each the FULL dotted/slashed path exactly as written:
# `import std/[os, sets]` yields `std/os` and `std/sets`, NOT `os` and `sets`.
# That distinction is the whole point — see `imported_test_modules` below.
#
# Text that is not code is removed first, because an import that Nim never
# compiles must not grant coverage:
#   * `# …` line comments, `#[ … ]#` block comments (nesting), and `""" … """`
#     long strings — the last is how a `discard """ … """` test spec is written,
#     and it is full of prose that can contain the word `import`;
#   * the indented body of EVERY conditional head — `when`, `elif`, `else:` —
#     identified by indentation, whatever the condition says. A text check
#     cannot evaluate a `when`, and the two failure directions are not
#     symmetric: reading an import Nim never compiles GRANTS a free pass, while
#     skipping one it does compile only costs a file its exemption and makes it
#     register. Enumerating spellings was tried and was WRONG — skipping only
#     `when false:` and `when [not] defined(…)` left `elif defined(…)`, `else:`,
#     `when hostOS == …` and `when compiles(…)` read as live code, and this host
#     compiles none of those bodies. An `else:` branch does sit at the `when`'s
#     own indentation, which is why it needs its own head match and not just the
#     `when`'s skip range.
# Ordinary `"…"` strings are deliberately left alone, but note what that does
# NOT buy: `include "helpers/x.nim"` really is legitimate Nim and really does
# open `tests/helpers/x.nim` (measured), yet the token keeps its `.nim` so the
# candidate becomes `tests/helpers/x.nim.nim` and matches nothing — the quoted
# include form is NOT resolved by this gate, it just fails closed. A single-line
# `discard "import x"` does not begin with `import`, so it is not read as one.
nim_import_tokens() {
  awk '
    # ---- strip comments and long strings -----------------------------------
    function decomment(line,   out, i, n, c2, c1) {
      out = ""; i = 1; n = length(line)
      while (i <= n) {
        c2 = substr(line, i, 3)
        c1 = substr(line, i, 2)
        if (tstr) {
          if (c2 == "\"\"\"") { tstr = 0; i += 3 } else { i += 1 }
          continue
        }
        if (depth > 0) {
          if (c1 == "]#") { depth -= 1; i += 2 }
          else if (c1 == "#[") { depth += 1; i += 2 }
          else { i += 1 }
          continue
        }
        if (c2 == "\"\"\"") { tstr = 1; i += 3; continue }
        if (c1 == "#[") { depth = 1; i += 2; continue }
        if (substr(line, i, 1) == "#") { break }   # line comment runs to EOL
        out = out substr(line, i, 1)
        i += 1
      }
      return out
    }
    function indentOf(line,   m) {
      m = match(line, /[^ \t]/)
      return (m == 0) ? -1 : m - 1
    }
    # ---- the leading word, normalised the way NIM compares identifiers ------
    # Nim keywords are matched with the same partial style-insensitivity as
    # identifiers: the FIRST character is case-sensitive, every later character
    # ignores case AND underscores. `wHen`, `w_hen`, `el_if` and `el_se` are all
    # real keywords — measured with the compiler, each one skipping the body a
    # literal `^when[ \t]` text match would have read. A regex over the literal
    # spelling is therefore evadable by spelling alone, so the leading word is
    # normalised before it is compared.
    function leadWord(s,   w, i, c, out) {
      if (match(s, /^[A-Za-z][A-Za-z0-9_]*/) == 0) return ""
      w = substr(s, 1, RLENGTH)
      out = substr(w, 1, 1)
      for (i = 2; i <= length(w); i++) {
        c = substr(w, i, 1)
        if (c != "_") out = out tolower(c)
      }
      return out
    }
    # ---- `std/[a, b]` -> `std/a, std/b` ------------------------------------
    function expand(s,   res, p, q, pre, inner, rest, prefix, head, k, m, parts, acc) {
      res = ""
      while ((p = index(s, "[")) > 0) {
        q = index(s, "]")
        if (q < p) break                       # unbalanced; leave the rest as-is
        pre = substr(s, 1, p - 1)
        inner = substr(s, p + 1, q - p - 1)
        rest = substr(s, q + 1)
        prefix = pre
        sub(/^.*[ \t,]/, "", prefix)           # the group prefix, e.g. `std/`
        head = substr(pre, 1, length(pre) - length(prefix))
        m = split(inner, parts, ",")
        acc = ""
        for (k = 1; k <= m; k++) {
          gsub(/^[ \t]+|[ \t]+$/, "", parts[k])
          if (parts[k] == "") continue
          acc = acc (acc == "" ? "" : ", ") prefix parts[k]
        }
        res = res head acc
        s = rest
      }
      return res s
    }
    BEGIN { depth = 0; tstr = 0; skipIndent = -1 }
    {
      # A UTF-8 BOM is three bytes Nim silently skips (measured: a file whose
      # first line is BOM + `when defined(neverDefined):` compiles, and does NOT
      # compile the body). Left in place it defeats the `^` in every head match
      # below, so line 1 alone would have its conditional body READ and would
      # grant coverage for a module nothing compiles. LC_ALL=C is exported at the
      # top of this script, so awk counts bytes here and substr() sees the BOM.
      if (NR == 1 && substr($0, 1, 3) == "\357\273\277") $0 = substr($0, 4)
      line = decomment($0)
      if (line ~ /^[ \t]*$/) next
      ind = indentOf(line)
      if (skipIndent >= 0) {
        if (ind > skipIndent) next
        skipIndent = -1
      }
      body = line
      gsub(/^[ \t]+|[ \t]+$/, "", body)
      # EVERY conditional-compilation head, not a list of spellings. Enumerating
      # `when false:` and `when [not] defined(…)` left `elif defined(…)`,
      # `else:`, `when hostOS == …` and `when compiles(…)` READ — and the
      # compiler compiles none of those four bodies on this host (measured), so
      # each one GRANTED an exemption for a file nothing compiles. Skipping the
      # whole indented body of the head, whatever the condition says, is the
      # only direction that fails closed.
      lw = leadWord(body)
      if (lw == "when" || lw == "elif" || lw == "else") { skipIndent = ind; next }
      if (body ~ /^from[ \t]/) { sub(/^from[ \t]+/, "", body); sub(/[ \t]+import[ \t].*$/, "", body) }
      else if (body ~ /^import[ \t]/) { sub(/^import[ \t]+/, "", body) }
      else if (body ~ /^include[ \t]/) { sub(/^include[ \t]+/, "", body) }
      else next
      # `import a / b` is ONE module path, not the module `a`. Nim allows the
      # spaces (verified: it compiles `tests/a/b.nim`), and without this the
      # token was `a` — granting `tests/a.nim` an exemption it has not earned
      # and leaving `tests/a/b.nim` unaccounted for.
      gsub(/[ \t]*\/[ \t]*/, "/", body)
      m = split(expand(body), items, ",")
      for (k = 1; k <= m; k++) {
        tok = items[k]
        gsub(/^[ \t]+|[ \t]+$/, "", tok)
        sub(/[ \t].*$/, "", tok)               # drop `as alias`, `except x`
        gsub(/"/, "", tok)
        if (tok != "") print tok
      }
    }
  ' "$1"
}

# Repo-relative paths of the tests/ modules FILE imports or includes, resolved
# the way the COMPILER resolves them. A token names EXACTLY ONE file, because
# `nim c` opens exactly one:
#
#   * `<dir of FILE>/<token>.nim` IF IT EXISTS — Nim looks beside the importing
#     module first and stops there, so `tests/sub/a.nim` with `import sibling`
#     compiles `tests/sub/sibling.nim`;
#   * otherwise `tests/<token>.nim` — both runners pass `--path:tests`, so a bare
#     `import ac_index_model` from `tests/x.nim` compiles `tests/ac_index_model.nim`,
#     and `import helpers/foo` compiles `tests/helpers/foo.nim`.
#
# Offering BOTH, as this did, was fail-OPEN. Asked of the compiler twice: with
# `tests/helpers/tok.nim` and `tests/tok.nim` both present, `import tok` from
# `tests/helpers/…` builds clean while the `tests/` copy holds a `{.error.}`
# that never fires — the sibling is the only file opened; remove the sibling and
# the same `{.error.}` fires immediately. So the `tests/` copy was compiled by
# nothing and reported as covered. The rule holds for slashed tokens too:
# `import sub2/mm` from `tests/helpers/` opens `tests/helpers/sub2/mm.nim` and
# leaves `tests/sub2/mm.nim` untouched (measured the same way).
#
# The match is ANCHORED to that one path. It used to be a path SUFFIX
# (`*/"$tok".nim`), which is depth-blind: `import ac_index_model` also claimed
# `tests/keyed/ac_index_model.nim`, `tests/x/y/shm_gset.nim` and
# `tests/x/shm_gset/transport.nim` — files `nim c` will not open. The compiler
# was asked directly: `import mymod` from `tests/t.nim` with `tests/sub/mymod.nim`
# on disk fails with `Error: cannot open file: mymod`. A gate whose scope
# paragraph advertises a `tests/keyed/` subdirectory cannot be blind to depth.
#
# A `std/…` token is dropped outright: Nim resolves it inside its own standard
# library and never opens a repo file for it. `import std/[os, sets]` does NOT
# compile a sibling `tests/std/os.nim` — the probe fails with `undeclared
# identifier` — so granting that file an exemption would name a live hole as
# covered. It is unaccounted for, and must be registered.
#
# The token itself is the module's FULL path as written, which is what keeps a
# stdlib import from claiming a same-named local file in the first place:
# exploding a bracket group into the bare names `os` and `sets` (as this did
# until the tokens were qualified) handed a silent free pass to `tests/os.nim`,
# `tests/sets.nim`, `tests/unittest.nim` and every other file named after a
# module the suite already imports. Those are ordinary names to reach for, so it
# was reachable by accident, not only by malice.
imported_test_modules() {
  local file="$1" tok cand rel dir base relative
  local -a cands
  rel="${file#"$REPO_ROOT/"}"
  dir="${rel%/*}"
  [ "$dir" = "$rel" ] && dir="."
  nim_import_tokens "$file" |
    while IFS= read -r tok; do
      # A `./` or `../` token is resolved PURELY relative to the importing file
      # — Nim does not consult the search path for it — and `../` really does
      # walk up: `import ../ac_index_model` from `tests/t.nim` compiles
      # `<repo>/ac_index_model.nim`, NOT `tests/ac_index_model.nim` (verified
      # with the compiler). Stripping the `../` and matching under `tests/`, as
      # this did, handed the exemption to the wrong file — and to one Nim never
      # opened.
      base="$dir"
      relative=0
      while :; do
        case "$tok" in
          ./*) tok="${tok#./}"; relative=1 ;;
          ../*)
            tok="${tok#../}"
            relative=1
            case "$base" in
              */*) base="${base%/*}" ;;
              *) base="." ;; # above tests/, i.e. out of this gate's scope
            esac
            ;;
          *) break ;;
        esac
      done
      [ -n "$tok" ] || continue
      case "$tok" in
        std/*) continue ;; # the stdlib; can never name a file in this repo
      esac
      # EXACTLY ONE candidate, because the compiler opens exactly one file.
      # Offering both the sibling and the `--path:tests` copy granted the
      # exemption to a file `nim c` never opened: with `tests/helpers/tok.nim`
      # AND `tests/tok.nim` on disk, the compiler opens the SIBLING and the
      # `tests/` copy is compiled by nothing (measured twice — see the header).
      if [ "$relative" = "1" ]; then
        cands=("$base/$tok.nim")
      elif [ -f "$REPO_ROOT/$dir/$tok.nim" ]; then
        cands=("$dir/$tok.nim")
      else
        cands=("tests/$tok.nim")
      fi
      for cand in "${cands[@]}"; do
        # Exact, whole-line match against the discovered set: no globbing, no
        # suffix, no depth slack.
        if printf '%s\n' "$all_nim" | grep -Fxq -- "$cand"; then
          printf '%s\n' "$cand"
        fi
      done
    done
}

# Transitive closure: registered compiles, plus everything they pull in.
covered="$registered"
while :; do
  prev_n="$(printf '%s\n' "$covered" | grep -c . || true)"
  more=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$REPO_ROOT/$f" ] || continue
    more="$more$(imported_test_modules "$REPO_ROOT/$f")"$'\n'
  done <<<"$covered"
  covered="$(printf '%s\n%s\n' "$covered" "$more" | grep . | LC_ALL=C sort -u || true)"
  now_n="$(printf '%s\n' "$covered" | grep -c . || true)"
  [ "$now_n" -gt "$prev_n" ] || break
done

unaccounted="$(comm -23 <(printf '%s\n' "$on_disk") <(printf '%s\n' "$covered") || true)"

# A module is exempt because a registered test IMPORTS it, and an import runs
# its top level — which is where a `unittest` suite lives. A `when isMainModule`
# body is the one thing an importer does NOT execute, so a file claiming the
# import exemption while hiding its cases behind that guard is exempt on a
# premise that is false for exactly the code that matters.
#
# The guard is found by NORMALISING each line the way Nim compares identifiers,
# not by matching the literal text `when isMainModule`: Nim keywords and
# identifiers alike ignore case and underscores after their first character, so
# `w_hen is_main_module:` is the very same guard and a literal grep does not see
# it (measured — that spelling compiles, and its body runs only as main). Any
# `when`/`elif` head mentioning the identifier `isMainModule` anywhere in its
# condition counts, which also covers `when(isMainModule):` and
# `when defined(x) and isMainModule:`.
has_main_module_guard() {
  awk '
    function norm(w,   i, c, out) {
      out = substr(w, 1, 1)
      for (i = 2; i <= length(w); i++) {
        c = substr(w, i, 1)
        if (c != "_") out = out tolower(c)
      }
      return out
    }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (match(line, /^[A-Za-z][A-Za-z0-9_]*/) == 0) next
      if (norm(substr(line, 1, RLENGTH)) != "when" &&
          norm(substr(line, 1, RLENGTH)) != "elif") next
      rest = substr(line, RLENGTH + 1)
      while (match(rest, /[A-Za-z][A-Za-z0-9_]*/) > 0) {
        if (norm(substr(rest, RSTART, RLENGTH)) == "ismainmodule") { found = 1; exit }
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$1"
}
import_exempt="$(comm -13 <(printf '%s\n' "$registered") <(printf '%s\n' "$covered") || true)"
guarded=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$REPO_ROOT/$f" ] || continue
  if has_main_module_guard "$REPO_ROOT/$f"; then
    guarded="${guarded}${f}"$'\n'
  fi
done < <(printf '%s\n' "$import_exempt")
if [ -n "${guarded//[$'\n']/}" ]; then
  rc=1
  echo "check-runner-parity: module(s) exempt only because a registered test imports them, but whose cases sit behind \`when isMainModule\`:" >&2
  printf '%s' "$guarded" | grep . | sed 's/^/  /' >&2
  echo "  An importer never runs that block, so the exemption does not cover it." >&2
  echo "  Register the file with BOTH runners, or drop the guard." >&2
fi

unregistered=""
orphan_helpers=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    tests/helpers/*)
      # A fixture is exempt from registration, not from having a driver. If
      # nothing in the repo names it, it is not a fixture — it is a test file
      # someone parked where the gate does not look. The fixture itself and
      # THIS FILE are both excluded from the answer: a fixture cannot drive
      # itself, and neither can the gate that is asking the question.
      base="$(basename "$f" .nim)"
      drivers="$(
        grep -RIlF --exclude-dir=.git --exclude-dir=nimcache -- "$base" \
          "$REPO_ROOT/Justfile" "$REPO_ROOT/shm_gset.nimble" \
          "$REPO_ROOT/tests" "$REPO_ROOT/scripts" 2>/dev/null |
          grep -vxF -e "$REPO_ROOT/$f" -e "$SELF" || true
      )"
      [ -n "$drivers" ] || orphan_helpers="${orphan_helpers}${f}"$'\n'
      ;;
    *) unregistered="${unregistered}${f}"$'\n' ;;
  esac
done < <(printf '%s\n' "$unaccounted")

if [ -n "${unregistered//[$'\n']/}" ]; then
  rc=1
  echo "check-runner-parity: test file(s) on disk registered with NEITHER runner:" >&2
  printf '%s' "$unregistered" | grep . | sed 's/^/  /' >&2
  echo "  (scope is tests/**/*.nim at any depth and under any name — a file is exempt" >&2
  echo "   only if a registered compile imports it, or it is a tests/helpers/ fixture)" >&2
fi
if [ -n "${orphan_helpers//[$'\n']/}" ]; then
  rc=1
  echo "check-runner-parity: tests/helpers/ fixture(s) nothing in the repo drives:" >&2
  printf '%s' "$orphan_helpers" | grep . | sed 's/^/  /' >&2
  echo "  A fixture must be built by a runner, compiled by a test, or named by a recipe." >&2
fi

if [ "$rc" -ne 0 ]; then
  echo "check-runner-parity: FAILED. Register the file(s) in BOTH the Justfile \`test:\` recipe and the \`test\` task in shm_gset.nimble, with identical flags, and run them with \`-r\` on both sides." >&2
  exit 1
fi

ran_n=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ "${just_run[$f]:-0}" = "1" ] && ran_n=$((ran_n + 1)) || true
done < <(printf '%s\n' "$registered")
echo "check-runner-parity: OK — both runners compile the same $(printf '%s\n' "$just_list" | grep -c . || true) file(s) with identical flags, and both RUN the same $ran_n of them."
