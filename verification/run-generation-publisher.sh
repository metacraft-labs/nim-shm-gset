#!/usr/bin/env bash
# Run with the repository's pinned flake (just verify-generation-publisher).
# Models include the actual shipped C unit. Controls mutate disposable copies
# of that unit and must fail on the intended oracle, not a compiler/tool error.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
results="${SHM_GSET_PUBLISHER_RESULTS:-$(mktemp -d)}"
mkdir -p "$results"
source_unit="$root/src/shm_gset/generation_publisher.c"
driver=verification/core/generation_publisher_driver.c
classifier=verification/classify-generation-publisher-failure.pl
classifier_controls=verification/core/generation_publisher_classifier_controls.c
controls=(relaxed nonmonotonic omitted rebound armed-close stale-success unordered-readiness)
sha256sum "$source_unit" "$root/src/shm_gset/generation_publisher.h" \
  "$root/src/shm_gset/generation_publisher_internal.h" "$driver" \
  "$classifier" "$classifier_controls" "${BASH_SOURCE[0]}" > "$results/source.sha256"
# Explicit RC11, with auto-detection disabled so the tool cannot silently
# substitute its RA model for the binding/contention cases. fno-builtin only
# prevents synthesized libc intrinsics; no assertion or atomic is suppressed.
for case_id in 0 1 2 3 4 5 6; do
  genmc --rc11 -disable-mm-detector -unroll=8 -- -std=c11 -fno-builtin -DCASE="$case_id" \
    "$driver" > "$results/model-$case_id.log" 2>&1
  grep -q 'No errors were detected' "$results/model-$case_id.log"
  cc -std=c11 -O2 -pthread -DCASE="$case_id" "$driver" -o "$results/native-$case_id"
  "$results/native-$case_id"
  cc -std=c11 -O1 -g -pthread -fsanitize=address,undefined -DCASE="$case_id" \
    "$driver" -o "$results/asan-$case_id"
  ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
    "$results/asan-$case_id" > "$results/asan-$case_id.log" 2>&1
  cc -std=c11 -O1 -g -pthread -fsanitize=thread -DCASE="$case_id" \
    "$driver" -o "$results/tsan-$case_id"
  TSAN_OPTIONS=halt_on_error=1 "$results/tsan-$case_id" > "$results/tsan-$case_id.log" 2>&1
  echo "PASS publication case $case_id: actual unit, RC11, native, ASan/UBSan, TSAN"
done

# Disable ONLY the release edge on the actual publication CAS, leaving its
# control flow and setup intact. The reader must now be able to see the mark
# without the preceding payload. fno-builtin prevents LLVM synthesizing memset
# in cold release; GenMC 0.17 traps promoting that intrinsic. Atomics unchanged.
perl -0pe 's/(__atomic_compare_exchange_n\(s->word, &seen, g, 0,\s*)__ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE/$1__ATOMIC_RELAXED, __ATOMIC_RELAXED/ or die "publication CAS not found"' \
  "$source_unit" > "$results/relaxed.c"
# Replace the atomic compare/exchange by a release store. Under forced reset
# this can erase a newer generation, despite returning a stale status.
perl -0pe 's/__atomic_compare_exchange_n\(s->word, &seen, g, 0,\s*__ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE\)/(__atomic_store_n(s->word, g, __ATOMIC_RELEASE), 1)/ or die "publication CAS not found"' \
  "$source_unit" > "$results/nonmonotonic.c"
perl -0pe 's/__atomic_compare_exchange_n\(s->word, &seen, g, 0,\s*__ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE\)/1/ or die "publication CAS not found"' \
  "$source_unit" > "$results/omitted.c"
perl -0pe 's/return claimed;/return 1;/ or die "claim return not found"' \
  "$source_unit" > "$results/rebound.c"
perl -0pe 's/__atomic_store_n\(&s->binding, PREPARING, __ATOMIC_RELEASE\);/(void)s;/ or die "disarm not found"' \
  "$source_unit" > "$results/armed-close.c"
perl -0pe 's/if \(__atomic_load_n\(s->generation, __ATOMIC_ACQUIRE\) != g\)/if (0)/g or die "final generation observations not found"' \
  "$source_unit" > "$results/stale-success.c"
perl -0pe 's/__atomic_store_n\(&s->binding, ARMED, __ATOMIC_RELEASE\)/__atomic_store_n(\&s->binding, ARMED, __ATOMIC_RELAXED)/ or die "readiness publication not found"' \
  "$source_unit" > "$results/unordered-readiness.c"
for control in "${controls[@]}"; do
  case "$control" in
    relaxed|armed-close) case_id=0 ;;
    nonmonotonic) case_id=2 ;;
    omitted) case_id=1 ;;
    rebound) case_id=3 ;;
    stale-success) case_id=4 ;;
    unordered-readiness) case_id=6 ;;
  esac
  printf '#define SHM_GSET_PUBLISHER_SOURCE "%s"\n#include "%s"\n' \
    "$results/$control.c" "$root/$driver" > "$results/$control-driver.c"
  status=0
  genmc --rc11 -disable-mm-detector -unroll=8 -- -std=c11 -fno-builtin -DCASE="$case_id" \
    -I "$root/src/shm_gset" "$results/$control-driver.c" \
    > "$results/$control.log" 2>&1 || status=$?
  printf '%s\n' "$status" > "$results/$control.status"
  perl "$classifier" "$control" "$status" "$results/$control.log" \
    "$driver" "$results/$control.c" | tee "$results/$control.classification"
  sha256sum "$results/$control.c" >> "$results/source.sha256"
  diff -u "$source_unit" "$results/$control.c" > "$results/$control.patch" || [ "$?" -eq 1 ]
  sha256sum "$results/$control.patch" >> "$results/source.sha256"
  echo "PASS sensitivity: $control rejected by the actual-unit oracle"
done

# These are real GenMC failures, including unrelated failures AFTER a successful
# publication. Every mutation classifier must reject them; neither an error
# category nor prepared-field accesses elsewhere in the trace are sufficient.
for fixture_case in 0 1 2 3; do
  fixture_unit="$source_unit"
  # Case 3 publishes in one thread using the readiness mutant, then races on
  # unrelated data in two new threads. Thus the trace contains first.captured
  # write/read events at the exact expected unit/sites, but THEY DO NOT CONFLICT.
  # Only the error's reported event pair decides the readiness classification.
  if [ "$fixture_case" -eq 3 ]; then fixture_unit="$results/unordered-readiness.c"; fi
  printf '#define SHM_GSET_PUBLISHER_SOURCE "%s"\n#include "%s"\n' \
    "$fixture_unit" "$root/$classifier_controls" > "$results/wrong-$fixture_case-driver.c"
  status=0
  genmc --rc11 -disable-mm-detector -unroll=8 -- -std=c11 -fno-builtin \
    -DCLASSIFIER_CASE="$fixture_case" -I "$root/src/shm_gset" "$results/wrong-$fixture_case-driver.c" \
    > "$results/wrong-$fixture_case.log" 2>&1 || status=$?
  printf '%s\n' "$status" > "$results/wrong-$fixture_case.status"
  test "$status" -eq 42
  # Prove that the intended unrelated failure occurred, rather than accepting
  # a compiler failure or a setup/publication assertion as a negative control.
  if (( fixture_case % 2 == 0 )); then
    oracle_line=$(awk '/CLASSIFIER_CONTROL: unrelated_assertion/ { print NR }' "$classifier_controls")
    grep -Fxq 'Error: Safety violation!' "$results/wrong-$fixture_case.log"
    grep -Eq ": ERROR $(basename "$classifier_controls"):$oracle_line$" "$results/wrong-$fixture_case.log"
  else
    oracle_line=$(awk '/CLASSIFIER_CONTROL: unrelated_race/ { print NR }' "$classifier_controls")
    grep -Fxq 'Error: Non-atomic race!' "$results/wrong-$fixture_case.log"
    test "$(grep -Ec ": Wna \(unrelated, [^)]*\) $(basename "$classifier_controls"):$oracle_line$" \
      "$results/wrong-$fixture_case.log")" -eq 2
  fi
  for control in "${controls[@]}"; do
    classification=0
    perl "$classifier" "$control" "$status" "$results/wrong-$fixture_case.log" \
      "$driver" "$results/$control.c" > "$results/wrong-$fixture_case-$control.classification" \
      2>&1 || classification=$?
    if [ "$classification" -ne 1 ]; then
      echo "FAIL: $control classifier did not reject wrong fixture $fixture_case (status $classification)" >&2
      exit 1
    fi
    cat "$results/wrong-$fixture_case-$control.classification"
  done
  echo "PASS classifier negative control $fixture_case: all seven reject the unrelated failure"
done

# Optimized production object must have no external symbol references: this
# catches TLS/errno/runtime/libatomic calls, including cold paths in this unit.
cc -std=c11 -O2 -Wall -Wextra -Werror -c "$source_unit" -o "$results/publisher.o"
nm -u "$results/publisher.o" > "$results/undefined-symbols.log"
test ! -s "$results/undefined-symbols.log"
echo "PASS production unit has no undefined symbols"

# Exercise the compiled unsupported branch rather than assuming a target with
# non-lock-free uint64 will fail safely. No fallback libatomic is linked.
printf '#undef __GCC_ATOMIC_LLONG_LOCK_FREE\n#include "%s"\n#include <assert.h>\nint main(void) { shm_gset_prepared_generation_publisher s = SHM_GSET_GENERATION_PUBLISHER_INIT; assert(!shm_gset_publisher_atomics_supported()); assert(!shm_gset_publisher_claim(&s)); assert(!shm_gset_publisher_arm(&s, 0, 0, 0)); assert(shm_gset_publish_prepared_generation(&s) == SHM_GSET_UNAVAILABLE); shm_gset_publisher_disarm(&s); shm_gset_publisher_release(&s); }\n' \
  "$source_unit" > "$results/unsupported.c"
cc -std=c11 -O2 -Wall -Wextra -Werror "$results/unsupported.c" -o "$results/unsupported"
"$results/unsupported"
echo "PASS unsupported-atomics branch refuses preparation/publication"

# The public C declaration binds the source unit locally within a consuming
# image. Check a real shared library call site, not just the leaf's symbol list.
printf '#include "%s"\nint caller(shm_gset_prepared_generation_publisher *s) { return shm_gset_publish_prepared_generation(s); }\n' \
  "$root/src/shm_gset/generation_publisher.h" > "$results/caller.c"
cc -std=c11 -O2 -fPIC -shared "$source_unit" "$results/caller.c" -o "$results/publisher.so"
readelf --relocs "$results/publisher.so" > "$results/relocations.log"
if grep -q 'shm_gset_' "$results/relocations.log"; then
  echo "FAIL: publisher call requires dynamic symbol resolution" >&2; exit 1
fi
echo "PASS shared-image caller has no dynamic publisher relocation"
echo "Evidence: $results"
