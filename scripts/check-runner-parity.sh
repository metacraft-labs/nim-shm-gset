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
#       file nothing imports — nor for one whose cases hide behind
#       `when isMainModule`, which an importer does not execute;
#   (c) it lives in `tests/helpers/`, the fixture directory for programs driven
#       by something other than the `test` runners (a test that compiles a
#       negative-compilation probe at runtime, the `test-valgrind` recipe). To
#       keep that from becoming a hiding place, an unregistered, unimported
#       helper must still be REFERENCED by name somewhere in the repo; an
#       orphaned one is an error.
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

# --- 4: every .nim under tests/ is accounted for --------------------------
# `-L` so a symlinked file or subdirectory under tests/ is discovered too,
# rather than being an unlisted way out of the scope.
on_disk="$(cd "$REPO_ROOT" && find -L tests -type f -name '*.nim' -printf '%p\n' | LC_ALL=C sort)"
[ -n "$on_disk" ] || fail "no tests/**/*.nim found — run this from the repo"
all_nim="$on_disk"

# Repo-relative paths of the tests/ modules FILE imports or includes. Nim
# resolves a bare `import ac_index_model` through `--path:tests`, so a token is
# matched against the discovered files by path SUFFIX: `ac_index_model` matches
# `tests/ac_index_model.nim`, `helpers/foo` matches `tests/helpers/foo.nim`,
# and `std/strutils` matches nothing unless `tests/std/strutils.nim` exists.
imported_test_modules() {
  local file="$1" line tok cand
  sed -n 's/#.*$//; s/^[[:space:]]*//; /^\(import\|include\|from\)[[:space:]]/p' "$file" |
    while IFS= read -r line; do
      case "$line" in
        from\ *)
          line="${line#from }"
          line="${line%% import*}"
          ;;
        import\ *) line="${line#import }" ;;
        include\ *) line="${line#include }" ;;
      esac
      line="${line//[/ }"
      line="${line//]/ }"
      line="${line//,/ }"
      for tok in $line; do
        case "$tok" in as | except | nil) continue ;; esac
        tok="${tok//\"/}"
        while :; do
          case "$tok" in
            ./*) tok="${tok#./}" ;;
            ../*) tok="${tok#../}" ;;
            *) break ;;
          esac
        done
        [ -n "$tok" ] || continue
        while IFS= read -r cand; do
          [ -n "$cand" ] || continue
          # Literal suffix match — `case` patterns quote the token, so a module
          # name is never read as a glob.
          case "$cand" in
            */"$tok".nim | "$tok".nim) printf '%s\n' "$cand" ;;
          esac
        done <<<"$all_nim"
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
import_exempt="$(comm -13 <(printf '%s\n' "$registered") <(printf '%s\n' "$covered") || true)"
guarded=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$REPO_ROOT/$f" ] || continue
  if grep -Eq '^[[:space:]]*when[[:space:]]+isMainModule' "$REPO_ROOT/$f"; then
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
      # someone parked where the gate does not look.
      base="$(basename "$f" .nim)"
      drivers="$(
        grep -RIlF --exclude-dir=.git --exclude-dir=nimcache -- "$base" \
          "$REPO_ROOT/Justfile" "$REPO_ROOT/shm_gset.nimble" \
          "$REPO_ROOT/tests" "$REPO_ROOT/scripts" 2>/dev/null |
          grep -v "^$REPO_ROOT/$f\$" || true
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
