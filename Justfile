# nim-shm-set test + benchmark runner.
#
# `nimble test` also works, but only once the repo has at least one commit
# (nimble derives the package version from the VCS revision). This `just`
# runner needs no commit, so it is the blessed runner during development.

nim_flags := "--hints:off --threads:on --warning:BareExcept:off --path:src"

# Build + run the full test suite (functional + multi-process concurrency).
test:
    nim c -r {{nim_flags}} tests/test_shm_set.nim
    nim c -r {{nim_flags}} -d:shmSetScheduleHooks tests/test_shm_set_hooks.nim

# Build + run the M1 transport head-to-head benchmark (needs nim-shm-queue).
bench:
    nim c -r {{nim_flags}} -d:release --path:../nim-shm-queue/src \
        benchmarks/bench_transports.nim
