/*  test_threadcpu.c -- self-test for libthreadcpu, run by ./build on Unix.

    Loads the freshly built library the way Poly/ML will (dlopen) and checks:
      1. a thread's own clock advances by about the CPU it burns;
      2. another thread can read that clock through the same handle;
      3. after the thread has ended the handle reads -1 (Linux/macOS).
    Prints the measurements; exit status 1 on any failure.                 */

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

typedef int64_t (*self_fn)(void);
typedef int64_t (*read_fn)(int64_t);
typedef void    (*free_fn)(int64_t);

static self_fn tc_self;
static read_fn tc_read;
static free_fn tc_free;

static double wall_now(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Burn CPU for about `seconds' of wall time; the loop is compute-bound so the
   thread's CPU clock should advance by nearly the same amount. */
static volatile uint64_t sink;
static void burn(double seconds)
{
  double t0 = wall_now();
  uint64_t x = 1;
  while (wall_now() - t0 < seconds) {
    for (int i = 0; i < 1000; i++) x = x * 6364136223846793005ULL + 1442695040888963407ULL;
    sink = x;
  }
}

/* volatile: the parent spins on it while the worker publishes its handle */
static volatile int64_t shared_handle;

static void *worker(void *arg)
{
  (void)arg;
  shared_handle = tc_self();
  burn(0.2);
  return NULL;
}

int main(int argc, char **argv)
{
  if (argc != 2) { fprintf(stderr, "usage: %s LIBRARY\n", argv[0]); return 1; }
  void *lib = dlopen(argv[1], RTLD_NOW);
  if (!lib) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1; }
  tc_self = (self_fn)dlsym(lib, "tc_self");
  tc_read = (read_fn)dlsym(lib, "tc_read");
  tc_free = (free_fn)dlsym(lib, "tc_free");
  if (!tc_self || !tc_read || !tc_free) { fprintf(stderr, "missing symbol\n"); return 1; }

  int failures = 0;

  /* 1. own clock */
  int64_t h = tc_self();
  if (h == 0) { fprintf(stderr, "tc_self failed\n"); return 1; }
  int64_t a = tc_read(h);
  burn(0.1);
  int64_t b = tc_read(h);
  double own_ms = (b - a) / 1e6;
  printf("own thread:   burned 100 ms wall, clock advanced %.1f ms\n", own_ms);
  if (own_ms < 80.0 || own_ms > 150.0) { printf("  FAIL: outside [80,150]\n"); failures++; }
  tc_free(h);

  /* 2. cross-thread read; 3. handle after thread exit */
  pthread_t t;
  shared_handle = 0;
  if (pthread_create(&t, NULL, worker, NULL) != 0) { fprintf(stderr, "pthread_create failed\n"); return 1; }
  while (shared_handle == 0) { /* wait for the worker to publish its handle */ }
  double t0 = wall_now();
  int64_t c0 = tc_read(shared_handle);
  burn(0.1);                                     /* parent stays busy meanwhile */
  int64_t c1 = tc_read(shared_handle);
  double parent_wall_ms = (wall_now() - t0) * 1e3;
  double cross_ms = (c1 - c0) / 1e6;
  printf("cross-thread: worker clock advanced %.1f ms over %.1f ms of parent wall\n",
         cross_ms, parent_wall_ms);
  if (c0 < 0 || c1 < 0 || cross_ms < 0.5 * parent_wall_ms) { printf("  FAIL\n"); failures++; }
  pthread_join(t, NULL);
  /* pthread_join returns when the kernel clears the thread's tid word, a few
     microseconds BEFORE the task itself is released; until then the clock
     still reads.  So: poll, and report how long the handle outlived the join. */
  t0 = wall_now();
  int64_t after;
  int reads = 0;
  do { after = tc_read(shared_handle); reads++; } while (after != -1 && wall_now() - t0 < 1.0);
  printf("after exit:   handle invalid after %.3f ms and %d read(s) (last value %lld; expect -1 on Linux/macOS)\n",
         (wall_now() - t0) * 1e3, reads, (long long)after);
#if !defined(_WIN32)
  if (after != -1) { printf("  FAIL: handle still reads 1 s after join\n"); failures++; }
#endif
  tc_free(shared_handle);

  /* read cost */
  h = tc_self();
  t0 = wall_now();
  for (int i = 0; i < 1000000; i++) sink = (uint64_t)tc_read(h);
  printf("read cost:    %.0f ns per tc_read\n", (wall_now() - t0) * 1e9 / 1e6);
  tc_free(h);

  printf(failures ? "FAILED\n" : "OK\n");
  return failures ? 1 : 0;
}
