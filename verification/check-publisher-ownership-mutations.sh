#!/usr/bin/env bash
# Safe disposable source mutations. Never edit the checkout under measurement.
# Each selected Nim assertion has a green control before weakening its owner.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
results="${SHM_GSET_PUBLISHER_MUTATIONS:-$(mktemp -d)}"
mkdir -p "$results"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -R "$root/src" "$work/src"
mkdir "$work/tests"
cp "$root/tests/test_generation_publisher.nim" "$root/tests/xproc.nim" "$work/tests/"
cp -R "$root/tests/helpers" "$work/tests/helpers"
cp "$root/config.nims" "$work/config.nims"
impl=src/shm_gset/generation_publisher_impl.nim
cd "$work"
flags=(--hints:off --threads:on --path:src --path:tests -d:shmGSetScheduleHooks)
nim c "${flags[@]}" -o:"$work/probe" tests/test_generation_publisher.nim > "$results/control-build.log" 2>&1
"$work/probe" > "$results/control.log" 2>&1
if grep -q '\[FAILED\]' "$results/control.log"; then exit 1; fi
sha256sum "$root/$impl" "$root/tests/test_generation_publisher.nim" > "$results/source.sha256"
for control in leaked-attachment copyable; do
  cp "$root/$impl" "$work/$impl"
  case "$control" in
    leaked-attachment)
      perl -0pi -e 's/    owner.attachment.detach\(\)/    discard # mutation: leak the private attachment/ or die "detach not found"' "$impl"
      assertion='failed preparation releases storage, registration and mapping'
      ;;
    copyable)
      perl -0pi -e 's/proc `=copy`\*\[K\]\(dest: var GenerationPublisherOwner\[K\];\n    source: GenerationPublisherOwner\[K\]\) \{\.error:\n      "GenerationPublisherOwner is move-only; use move\(owner\)"\.\}\n// or die "copy guard not found"' "$impl"
      assertion='real compiler refuses copy and accepts the move control'
      ;;
  esac
  diff -u "$root/$impl" "$work/$impl" > "$results/$control.patch" || [ "$?" -eq 1 ]
  sha256sum "$work/$impl" "$results/$control.patch" >> "$results/source.sha256"
  nim c "${flags[@]}" -o:"$work/probe" tests/test_generation_publisher.nim > "$results/$control-build.log" 2>&1
  if "$work/probe" "$assertion" > "$results/$control.log" 2>&1; then
    echo "FAIL: $control mutation passed" >&2; exit 1
  fi
  grep -Fq "[FAILED] $assertion" "$results/$control.log"
  echo "PASS sensitivity: $control rejected by $assertion"
done
echo "Evidence: $results"
