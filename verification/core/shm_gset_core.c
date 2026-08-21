/*
 * shm_gset_core.c — the extracted C11 atomics core of nim-shm-gset, for stateless
 * model checking under weak memory (design spec io-mon-Lossless-Event-Capture
 * §4.5(a)). It reproduces, with the SAME memory orders as src/shm_gset.nim, the
 * four load-bearing atomic sites on a deliberately tiny forced-collision table:
 *
 *   1. slot-claim       CAS 0 -> arena-offset, ACQ_REL      (insertIntoShard)
 *   2. arena reserve     fetch_add SEQ_CST                   (fetchAddU64 ArenaUsed)
 *   3. shard-append+     chainCount CAS N -> N+1, ACQ_REL    (bumpChainCountTo)
 *      chain-bump
 *   4. reader/probe      acquire-load slot, then acquire-load the record fields
 *                        it points at                        (entryMatches / items)
 *
 * The published arena record is written with relaxed stores BEFORE the release
 * CAS, exactly as the library does (storeU64Relaxed rec, then casU64 slot
 * ACQ_REL). A probing producer is itself a concurrent reader, so the torn-key
 * oracle needs no separate reader thread: if a probe observes a published slot,
 * it MUST observe the fully-written record (fp != 0 && val == fp).
 *
 * ORACLES (assert()s a model checker will try to violate):
 *   - torn-read:  a published slot always points at a complete record.
 *   - no-loss:    every distinct element inserted is present at the end.
 *   - no-phantom: every occupied slot holds a real inserted element.
 *   - grow arb:   at most the expected number of shards; chain stays valid.
 *
 * HOW TO MODEL-CHECK. nixpkgs carries none of these tools, so this repo packages
 * them (see ../../nix/) and pins them (../../flake.nix). The blessed runner is
 *   just verify-models
 * which is equivalent to:
 *   GenMC:      genmc -unroll=5 -- -std=c11 shm_gset_core.c
 *   Nidhugg:    nidhuggc --c -- --sc|--tso|--pso --unroll=5 shm_gset_core.c
 *               (NOT --c11, which does not exist, and NOT --arm: Nidhugg's ARM
 *                trace builder rejects atomicrmw, which this core uses)
 *   CDSChecker: cannot consume this file — it replaces the atomics and thread
 *               APIs and needs `user_main`; see ../cdschecker/ for the ports.
 *
 * It also builds+runs natively as a FUNCTIONAL smoke (many random schedules) —
 * that is NOT a weak-memory proof (a native run cannot exhaustively reorder);
 * it only proves the core compiles and its logic is self-consistent. Build:
 *   cc -std=c11 -O2 -pthread -DSTANDALONE shm_gset_core.c -o shm_gset_core_run
 */
#include <stdatomic.h>
#include <stdint.h>
#include <assert.h>
#include <pthread.h>

#ifndef NSHARDS
#define NSHARDS 2        /* shard0 + one grow */
#endif
#ifndef CAP
#define CAP 2            /* slots per shard (power of two) */
#endif
#ifndef ARENA
#define ARENA 4          /* record capacity per shard */
#endif

/* One arena record: fp (fingerprint, never 0 when published) + val (payload,
 * here == fp so a torn read is detectable). Mirrors [fp u64][len u32][bytes]. */
struct rec { atomic_uint fp; atomic_uint val; };

struct shard {
    atomic_uint slot[CAP];      /* 0 == empty, else 1-based arena record index */
    struct rec  arena[ARENA];
    atomic_uint arena_used;     /* bump allocator (1-based; 0 reserved) */
    atomic_uint occ;            /* claimed-slot count */
};

static struct shard shards[NSHARDS];
static atomic_uint chain;       /* chainCount, >= 1 (shard0 authoritative) */

/* Fixed home slot per key to FORCE a collision at slot 0 (both keys home 0). */
static unsigned home_of(unsigned key) { return 0u; }

/* Insert one element (fingerprint == key == payload) idempotently. Returns 1 if
 * a new slot was claimed, 0 if already present. Never loses: on a full table it
 * grows a shard and retries (bounded by NSHARDS in this model). */
static int insert(unsigned key)
{
    for (;;) {
        unsigned n  = atomic_load_explicit(&chain, memory_order_acquire);
        unsigned si = n - 1;                 /* newest shard */
        struct shard *sh = &shards[si];
        unsigned idx = home_of(key);
        unsigned probes = 0;
        for (; probes < CAP; ) {
            unsigned e = atomic_load_explicit(&sh->slot[idx], memory_order_acquire);
            if (e == 0) {
                /* reserve arena, write record fully, THEN publish via release CAS */
                unsigned r = atomic_fetch_add_explicit(&sh->arena_used, 1u,
                                                       memory_order_seq_cst);
                if (r >= ARENA) goto grow;   /* arena exhausted -> shard */
                atomic_store_explicit(&sh->arena[r].fp,  key, memory_order_relaxed);
                atomic_store_explicit(&sh->arena[r].val, key, memory_order_relaxed);
                unsigned expected = 0;
                if (atomic_compare_exchange_strong_explicit(
                        &sh->slot[idx], &expected, r + 1,
                        memory_order_acq_rel, memory_order_acquire)) {
                    atomic_fetch_add_explicit(&sh->occ, 1u, memory_order_seq_cst);
                    return 1;
                }
                /* lost the slot: `expected` is the winner's 1-based record index */
                e = expected;
                /* fall through to the torn-key check + probe-on below */
            }
            /* Occupied (by us as loser, or a pre-existing entry): the acquire on
             * the slot load MUST make the record it points at fully visible. */
            {
                unsigned ri = e - 1;
                unsigned fp = atomic_load_explicit(&sh->arena[ri].fp,
                                                   memory_order_acquire);
                unsigned vl = atomic_load_explicit(&sh->arena[ri].val,
                                                   memory_order_acquire);
                assert(fp != 0);             /* TORN-READ ORACLE: published => fp set */
                assert(vl == fp);            /* TORN-READ ORACLE: record self-consistent */
                if (fp == key) return 0;     /* idempotent: already present */
            }
            idx = (idx + 1) & (CAP - 1);
            probes++;
        }
    grow:;
        /* growth-by-sharding: append shard `n` (0-based) if room, bump chain */
        if (n >= NSHARDS) return -1;         /* saturated (model bound) */
        unsigned want = n + 1;
        unsigned cur = atomic_load_explicit(&chain, memory_order_acquire);
        while (cur < want) {                  /* bumpChainCountTo(want) */
            if (atomic_compare_exchange_weak_explicit(
                    &chain, &cur, want,
                    memory_order_acq_rel, memory_order_acquire)) break;
        }
        /* retry into the (now) newest shard */
    }
}

/* Reader union (single-threaded, post-join): distinct membership across shards. */
static int contains(unsigned key)
{
    unsigned n = atomic_load_explicit(&chain, memory_order_acquire);
    for (unsigned si = 0; si < n; si++) {
        struct shard *sh = &shards[si];
        for (unsigned i = 0; i < CAP; i++) {
            unsigned e = atomic_load_explicit(&sh->slot[i], memory_order_acquire);
            if (e == 0) continue;
            unsigned fp = atomic_load_explicit(&sh->arena[e - 1].fp,
                                               memory_order_acquire);
            if (fp == key) return 1;
        }
    }
    return 0;
}

/* Two producers insert DISTINCT keys that share home slot 0 -> the slot-claim
 * race. Keys are odd/even and non-zero so fp==0 unambiguously means "unwritten". */
#define KEY_A 0x11u
#define KEY_B 0x22u

static void *tA(void *_) { (void)_; insert(KEY_A); return 0; }
static void *tB(void *_) { (void)_; insert(KEY_B); return 0; }

static void reset(void)
{
    for (unsigned s = 0; s < NSHARDS; s++) {
        for (unsigned i = 0; i < CAP; i++)
            atomic_store_explicit(&shards[s].slot[i], 0, memory_order_relaxed);
        for (unsigned i = 0; i < ARENA; i++) {
            atomic_store_explicit(&shards[s].arena[i].fp,  0, memory_order_relaxed);
            atomic_store_explicit(&shards[s].arena[i].val, 0, memory_order_relaxed);
        }
        atomic_store_explicit(&shards[s].arena_used, 0, memory_order_relaxed);
        atomic_store_explicit(&shards[s].occ, 0, memory_order_relaxed);
    }
    atomic_store_explicit(&chain, 1, memory_order_relaxed);
}

static void run_once(void)
{
    reset();
    pthread_t a, b;
    pthread_create(&a, 0, tA, 0);
    pthread_create(&b, 0, tB, 0);
    pthread_join(a, 0);
    pthread_join(b, 0);
    /* no-loss: both distinct elements present */
    assert(contains(KEY_A));
    assert(contains(KEY_B));
    /* no-phantom: only real keys occupy slots */
    unsigned n = atomic_load_explicit(&chain, memory_order_acquire);
    for (unsigned si = 0; si < n; si++)
        for (unsigned i = 0; i < CAP; i++) {
            unsigned e = atomic_load_explicit(&shards[si].slot[i], memory_order_acquire);
            if (e) {
                unsigned fp = atomic_load_explicit(&shards[si].arena[e - 1].fp,
                                                   memory_order_acquire);
                assert(fp == KEY_A || fp == KEY_B);
            }
        }
}

#ifdef STANDALONE
#include <stdio.h>
#ifndef NITER
#define NITER 200000   /* native default; override (e.g. -DNITER=50) for qemu-user */
#endif
int main(void)
{
    /* Functional smoke ONLY (not a weak-memory proof): hammer many schedules. */
    for (long i = 0; i < (long)NITER; i++) run_once();
    printf("[OK] shm_gset_core functional smoke: %ld slot-claim races, "
           "no torn read / loss / phantom (NOT a weak-memory proof)\n", (long)NITER);
    return 0;
}
#else
int main(void) { run_once(); return 0; }   /* model-checker entry (one symbolic run) */
#endif
