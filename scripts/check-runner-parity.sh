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
# WHAT IT CHECKS, all three as errors:
#   1. Same FILE SET. Every `tests/*.nim` compiled by one runner is compiled by
#      the other.
#   2. Same FLAG SET per file. A file built with `-d:shmGSetScheduleHooks` or
#      `-d:nimAllocStats` under one runner and without it under the other is a
#      silently WEAKER run, not a parity violation you would notice in a count
#      (both would still report the same number of [OK] lines). The two files
#      also used to disagree on `--path:tests`, which the Justfile applied to
#      every compile and the nimble task to four files only.
#   3. Every `tests/test_*.nim` ON DISK is registered. A new test file wired
#      into neither runner passes checks 1 and 2 vacuously.
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

# --- normalise one compile command into "<file>\t<sorted flag tokens>" ----
# Drops `nim`, `c`, `-r` and `-o:<path>`; the target is the `tests/*.nim`
# argument. Flags are sorted so argument ORDER is not treated as a difference.
emit_entry() {
  local cmd="$1" src="$2"
  local file="" flags=() tok
  for tok in $cmd; do
    case "$tok" in
      nim | c | -r) ;;
      -o:*) ;;
      tests/*.nim) file="$tok" ;;
      *) flags+=("$tok") ;;
    esac
  done
  [ -n "$file" ] || return 0 # a compile with no tests/*.nim target is not ours
  local sorted
  sorted="$(printf '%s\n' "${flags[@]:-}" | LC_ALL=C sort | tr '\n' ' ')"
  printf '%s\t%s\t%s\n' "$file" "${sorted% }" "$src"
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
    emit_entry "$line" justfile
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
        nim\ c\ *) emit_entry "$expr" nimble ;;
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

# --- 3: every test file on disk is registered somewhere -------------------
registered="$(printf '%s\n%s\n' "$just_list" "$nimble_list" | cut -f1 | LC_ALL=C sort -u)"
on_disk="$(cd "$REPO_ROOT" && find tests -maxdepth 1 -name 'test_*.nim' -printf '%p\n' | sort)"
[ -n "$on_disk" ] || fail "no tests/test_*.nim found — run this from the repo"

unregistered="$(comm -23 <(printf '%s\n' "$on_disk") <(printf '%s\n' "$registered"))"
if [ -n "$unregistered" ]; then
  rc=1
  echo "check-runner-parity: test file(s) on disk registered with NEITHER runner:" >&2
  printf '  %s\n' "$unregistered" >&2
fi

if [ "$rc" -ne 0 ]; then
  echo "check-runner-parity: FAILED. Register the file(s) in BOTH the Justfile \`test:\` recipe and the \`test\` task in shm_gset.nimble, with identical flags." >&2
  exit 1
fi

echo "check-runner-parity: OK — both runners compile the same $(printf '%s\n' "$just_list" | grep -c . || true) file(s) with identical flags."
