/*  tc_probe.c -- portable measurement harness for libthreadcpu / threadcpu.dll.
    Part of the thread-cpu-probe workflow; see .github/workflows/thread-cpu-probe.yml
    for the questions it answers.  Not a test: it NEVER fails on a measurement
    outcome, it only prints one labelled line per measurement.

    usage:  tc_probe LIBRARY [VARIANT-LABEL]

    Loads the library the way Poly/ML will (dlopen / LoadLibrary + dlsym /
    GetProcAddress).  Threads: pthreads on POSIX, Win32 CreateThread on Windows.
    Every output line starts with a tag "Mn"/"Wn" naming the question.        */

#ifdef _WIN32
#  define _WIN32_WINNT 0x0601
#  include <windows.h>
#else
#  include <dlfcn.h>
#  include <pthread.h>
#  include <time.h>
#endif

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef int64_t (*self_fn)(void);
typedef int64_t (*read_fn)(int64_t);
typedef void    (*free_fn)(int64_t);
typedef int64_t (*freerc_fn)(int64_t);   /* sendright variant only */

static self_fn   tc_self;
static read_fn   tc_read;
static free_fn   tc_free;
static freerc_fn tc_free_rc;             /* NULL unless the variant exports it */

/* ------------------------------------------------------------------ platform */

#ifdef _WIN32

static double wall_now(void)
{
  static LARGE_INTEGER freq;
  LARGE_INTEGER c;
  if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
  QueryPerformanceCounter(&c);
  return (double)c.QuadPart / (double)freq.QuadPart;
}
static void sleep_ms(int ms) { Sleep(ms); }

typedef HANDLE thr_t;
typedef void (*thr_body)(void);
static DWORD WINAPI thr_tramp(LPVOID p) { ((thr_body)p)(); return 0; }
static int thr_start(thr_t *t, thr_body f)
{ *t = CreateThread(NULL, 0, thr_tramp, (LPVOID)f, 0, NULL); return *t ? 0 : -1; }
static void thr_join(thr_t t) { WaitForSingleObject(t, INFINITE); CloseHandle(t); }

static void *lib_open(const char *p) { return (void *)LoadLibraryA(p); }
static void *lib_sym(void *l, const char *n) { return (void *)GetProcAddress((HMODULE)l, n); }
static const char *lib_err(void) { static char b[64]; sprintf(b, "GetLastError=%lu", (unsigned long)GetLastError()); return b; }

#else

static double wall_now(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}
static void sleep_ms(int ms)
{
  struct timespec ts;
  ts.tv_sec = ms / 1000;
  ts.tv_nsec = (long)(ms % 1000) * 1000000L;
  nanosleep(&ts, NULL);
}

typedef pthread_t thr_t;
typedef void (*thr_body)(void);
static void *thr_tramp(void *p) { ((thr_body)p)(); return NULL; }
static int thr_start(thr_t *t, thr_body f)
{ return pthread_create(t, NULL, thr_tramp, (void *)(uintptr_t)f); }
static void thr_join(thr_t t) { pthread_join(t, NULL); }

static void *lib_open(const char *p) { return dlopen(p, RTLD_NOW); }
static void *lib_sym(void *l, const char *n) { return dlsym(l, n); }
static const char *lib_err(void) { const char *e = dlerror(); return e ? e : "(none)"; }

#endif

/* --------------------------------------------------------------- CPU burning */

static volatile uint64_t sink;

static void burn(double seconds)
{
  double t0 = wall_now();
  uint64_t x = 1;
  while (wall_now() - t0 < seconds) {
    for (int i = 0; i < 1000; i++)
      x = x * 6364136223846793005ULL + 1442695040888963407ULL;
    sink = x;
  }
}

/* ------------------------------------------------------------- shared state */

static volatile int64_t shared_handle;   /* published by the measured worker */
static volatile int     stop_flag;

static void worker_body(void)
{
  shared_handle = tc_self();
  burn(0.30);
}

static void storm_body(void)          /* short-lived churn thread */
{
  volatile int64_t h = tc_self();
  burn(0.0005);
  if (h) tc_free(h);
}

static void alive_body(void)          /* stays alive burning until told to stop */
{
  int64_t h = tc_self();
  while (!stop_flag) burn(0.005);
  if (h) tc_free(h);
}

/* ================================================================== main */

int main(int argc, char **argv)
{
  const char *variant = (argc > 2) ? argv[2] : "unlabelled";
  if (argc < 2) { fprintf(stderr, "usage: %s LIBRARY [VARIANT]\n", argv[0]); return 2; }

  void *lib = lib_open(argv[1]);
  if (!lib) { fprintf(stderr, "LOAD FAILED %s: %s\n", argv[1], lib_err()); return 2; }
  tc_self    = (self_fn)  lib_sym(lib, "tc_self");
  tc_read    = (read_fn)  lib_sym(lib, "tc_read");
  tc_free    = (free_fn)  lib_sym(lib, "tc_free");
  tc_free_rc = (freerc_fn)lib_sym(lib, "tc_free_rc");
  if (!tc_self || !tc_read || !tc_free) { fprintf(stderr, "missing symbol\n"); return 2; }

  printf("VARIANT %s library=%s tc_free_rc_exported=%s\n",
         variant, argv[1], tc_free_rc ? "yes" : "no");
  fflush(stdout);

  /* ---- M2/W2 a: own clock while burning to a 100 ms wall deadline ---- */
  {
    int64_t h = tc_self();
    printf("M2a-handle    tc_self on main thread = %lld\n", (long long)h);
    double t0 = wall_now();
    int64_t a = tc_read(h);
    burn(0.100);
    int64_t b = tc_read(h);
    double wall_ms = (wall_now() - t0) * 1e3;
    printf("M2a-burn      wall %.3f ms -> own clock advanced %.3f ms (raw %lld -> %lld)\n",
           wall_ms, (b - a) / 1e6, (long long)a, (long long)b);
    tc_free(h);
  }

  /* ---- M2/W2 b: own clock across a 100 ms sleep ---- */
  {
    int64_t h = tc_self();
    double t0 = wall_now();
    int64_t a = tc_read(h);
    sleep_ms(100);
    int64_t b = tc_read(h);
    double wall_ms = (wall_now() - t0) * 1e3;
    printf("M2b-sleep     wall %.3f ms -> own clock advanced %.3f ms (raw %lld -> %lld)\n",
           wall_ms, (b - a) / 1e6, (long long)a, (long long)b);
    tc_free(h);
  }

  /* ---- M2/W2 c: another thread reads the worker's clock while it burns ---- */
  int64_t stale;                       /* the worker's handle, kept after exit */
  int64_t final_total = -2;            /* first read AFTER join */
  int64_t last_live = -2;              /* last read while the worker still ran */
  {
    thr_t t;
    shared_handle = 0;
    if (thr_start(&t, worker_body) != 0) { fprintf(stderr, "thread create failed\n"); return 2; }
    while (shared_handle == 0) { /* spin until the worker publishes */ }
    stale = shared_handle;
    printf("M2c-handle    worker handle = %lld\n", (long long)stale);
    double t0 = wall_now();
    int64_t c0 = tc_read(stale);
    burn(0.100);                       /* parent stays busy meanwhile */
    int64_t c1 = tc_read(stale);
    double parent_ms = (wall_now() - t0) * 1e3;
    printf("M2c-cross     worker clock advanced %.3f ms over %.3f ms of parent wall (raw %lld -> %lld)\n",
           (c1 - c0) / 1e6, parent_ms, (long long)c0, (long long)c1);

    /* ---- M3/W4: post-exit behaviour ---- */
    last_live = c1;
    thr_join(t);
    final_total = tc_read(stale);
    printf("M3-atjoin     first read after join = %lld ns (%.3f ms)\n",
           (long long)final_total, final_total / 1e6);
    t0 = wall_now();
    int64_t after = final_total;
    long reads = 0;
    double when = -1.0;
    while (wall_now() - t0 < 1.0) {
      after = tc_read(stale);
      reads++;
      if (after == -1) { when = (wall_now() - t0) * 1e3; break; }
    }
    if (when >= 0)
      printf("M3-postexit   BECAME -1 after %.3f ms and %ld read(s)\n", when, reads);
    else
      printf("M3-postexit   STILL VALID after 1.000 s and %ld read(s); last value %lld ns (%.3f ms)\n",
             reads, (long long)after, after / 1e6);
  }

  /* ---- M4: port-name reuse -- 200 short-lived threads, then read the stale handle ---- */
  {
    for (int i = 0; i < 200; i++) {
      thr_t t;
      if (thr_start(&t, storm_body) != 0) { printf("M4-storm      thread create failed at %d\n", i); break; }
      thr_join(t);
    }
    int64_t v = tc_read(stale);
    printf("M4a-afterstorm 200 short-lived threads created+joined; stale handle %lld reads %lld ns (%.3f ms); worker's last live read was %lld ns, first read after join %lld ns\n",
           (long long)stale, (long long)v, v / 1e6,
           (long long)last_live, (long long)final_total);

    /* and again with 32 threads still ALIVE, in case the name is handed to a live thread */
    enum { NALIVE = 32 };
    thr_t a[NALIVE];
    int started = 0;
    stop_flag = 0;
    for (int i = 0; i < NALIVE; i++) { if (thr_start(&a[i], alive_body) == 0) started++; else break; }
    sleep_ms(60);
    int64_t v2 = tc_read(stale);
    printf("M4b-alive     %d live churn threads; stale handle reads %lld ns (%.3f ms)\n",
           started, (long long)v2, v2 / 1e6);
    stop_flag = 1;
    for (int i = 0; i < started; i++) thr_join(a[i]);
    int64_t v3 = tc_read(stale);
    printf("M4c-afteralive stale handle reads %lld ns (%.3f ms)\n", (long long)v3, v3 / 1e6);
  }

  /* ---- M5 / W4 tail: release the stale handle and read once more ---- */
  {
    if (tc_free_rc) {
      int64_t rc = tc_free_rc(stale);
      printf("M5-free       tc_free_rc(stale) = %lld (%s)\n",
             (long long)rc, rc == 0 ? "KERN_SUCCESS" : "NON-ZERO");
    } else {
      tc_free(stale);
      printf("M5-free       tc_free(stale) returned (void; variant exports no tc_free_rc)\n");
    }
    int64_t v = tc_read(stale);
    printf("M5-afterfree  stale handle reads %lld ns\n", (long long)v);
  }

  /* ---- M2/W2 d: cost of one tc_read ---- */
  {
    int64_t h = tc_self();
    const long N = 1000000;
    double t0 = wall_now();
    for (long i = 0; i < N; i++) sink = (uint64_t)tc_read(h);
    double el = wall_now() - t0;
    printf("M2d-readcost  %ld reads in %.3f s = %.1f ns per tc_read\n", N, el, el * 1e9 / (double)N);
    tc_free(h);
  }

#ifdef _WIN32
  /* ---- W3: resolution of GetThreadTimes, and of QueryThreadCycleTime ---- */
  {
    int64_t h = tc_self();
    HANDLE hh = (HANDLE)(intptr_t)h;
    LARGE_INTEGER qpf; QueryPerformanceFrequency(&qpf);

    int64_t prev = tc_read(h), first = prev;
    int64_t minstep = 0, maxstep = 0;
    long distinct = 1, samples = 0;

    ULONG64 cprev = 0, cfirst = 0, clast = 0;
    QueryThreadCycleTime(hh, &cprev); cfirst = cprev; clast = cprev;
    ULONG64 cmin = 0, cmax = 0;
    long cdistinct = 1;

    double t0 = wall_now();
    while (wall_now() - t0 < 0.200) {
      int64_t v = tc_read(h);
      samples++;
      if (v != prev) {
        int64_t s = v - prev;
        if (minstep == 0 || (s > 0 && s < minstep)) minstep = s;
        if (s > maxstep) maxstep = s;
        distinct++; prev = v;
      }
      ULONG64 c;
      if (QueryThreadCycleTime(hh, &c)) {
        if (c != cprev) {
          ULONG64 s = c - cprev;
          if (cmin == 0 || (s > 0 && s < cmin)) cmin = s;
          if (s > cmax) cmax = s;
          cdistinct++; cprev = c;
        }
        clast = c;
      }
    }
    double el = wall_now() - t0;
    printf("W3a-gtt       %.3f s loop, %ld samples: %ld distinct GetThreadTimes values, min non-zero step %.3f us, max step %.3f us (first %lld, last %lld ns)\n",
           el, samples, distinct, minstep / 1e3, maxstep / 1e3, (long long)first, (long long)prev);
    printf("W3b-qtct      %ld distinct QueryThreadCycleTime values, min non-zero step %llu cycles, max step %llu cycles, total %llu cycles over %.6f s\n",
           cdistinct, (unsigned long long)cmin, (unsigned long long)cmax,
           (unsigned long long)(clast - cfirst), el);
    {
      double rate = (double)(clast - cfirst) / el;    /* cycles per second */
      printf("W3c-qtctres   implied cycle rate %.3f MHz (QPF=%lld Hz) -> min step %.3f cycles = %.4f us\n",
             rate / 1e6, (long long)qpf.QuadPart, (double)cmin, cmin / rate * 1e6);
    }

    /* burn exactly 3 ms of wall clock and see whether GetThreadTimes moved */
    {
      int64_t a = tc_read(h);
      double s0 = wall_now();
      burn(0.003);
      double w = (wall_now() - s0) * 1e3;
      int64_t b = tc_read(h);
      printf("W3d-3ms       burned %.3f ms wall -> GetThreadTimes advanced %lld ns (%.4f ms)\n",
             w, (long long)(b - a), (b - a) / 1e6);
    }
    /* repeat 10x so a 0 is not a fluke */
    {
      int zeros = 0;
      int64_t steps[10];
      for (int i = 0; i < 10; i++) {
        int64_t a = tc_read(h);
        burn(0.003);
        int64_t b = tc_read(h);
        steps[i] = b - a;
        if (b == a) zeros++;
      }
      printf("W3e-3ms-x10   advances (ns):");
      for (int i = 0; i < 10; i++) printf(" %lld", (long long)steps[i]);
      printf("   zeros=%d/10\n", zeros);
    }
    tc_free(h);
  }

  /* ---- W4 tail: read after CloseHandle already done above as M5-afterfree ---- */
#endif

  printf("PROBE DONE variant=%s\n", variant);
  fflush(stdout);
  return 0;
}
