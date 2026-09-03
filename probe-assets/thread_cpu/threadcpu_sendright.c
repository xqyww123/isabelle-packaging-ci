/*  threadcpu.c -- per-thread CPU time for Isabelle/ML (library/thread_cpu.ML).

    Three entry points, identical on every platform, so the ML side needs no
    platform switch of its own:

      tc_self()    an opaque handle for the CALLING thread's CPU clock.  Must run
                   ON the thread being measured.  Returns 0 on failure.  The
                   handle is valid process-wide: any other thread may pass it to
                   tc_read.  That is what makes a watchdog thread possible.
      tc_read(h)   CPU nanoseconds consumed by that thread, or -1 if the handle
                   is no longer valid.  On Linux and macOS a finished thread
                   reports exactly that; on Windows the duplicated handle keeps
                   the thread object alive, so the final total keeps reading.
      tc_free(h)   release whatever the handle owns.  A no-op except on Windows.

    Why a C shim at all: each platform reports thread CPU through a different
    struct (timespec / thread_basic_info / FILETIME).  Encoding those layouts
    by hand in ML is where this would rot: Foreign.Memory's accessors index in
    units of the read width, not bytes, and getting that wrong returns
    plausible-looking garbage rather than an error.  Here the headers define
    the layouts.

    Resolution of the READ differs by platform: Linux reports nanoseconds,
    macOS microseconds; what GetThreadTimes actually resolves to on Windows
    has not been measured by this project and must be before a Windows CPU
    budget is trusted.  Only the Linux branch has been verified so far.      */

#include <stdint.h>

#if defined(_WIN32)

#include <windows.h>

int64_t tc_self(void)
{
  HANDLE dup;
  /* GetCurrentThread() is a pseudo-handle, meaningful only to the calling
     thread; duplicate it so a watchdog thread can use it. */
  if (!DuplicateHandle(GetCurrentProcess(), GetCurrentThread(),
                       GetCurrentProcess(), &dup,
                       THREAD_QUERY_INFORMATION, FALSE, 0))
    return 0;
  return (int64_t)(intptr_t)dup;
}

int64_t tc_read(int64_t h)
{
  FILETIME creation, exit, kernel, user;
  ULARGE_INTEGER k, u;
  if (h == 0) return -1;
  if (!GetThreadTimes((HANDLE)(intptr_t)h, &creation, &exit, &kernel, &user))
    return -1;
  k.LowPart = kernel.dwLowDateTime; k.HighPart = kernel.dwHighDateTime;
  u.LowPart = user.dwLowDateTime;   u.HighPart = user.dwHighDateTime;
  /* FILETIME counts 100 ns units. */
  return (int64_t)((k.QuadPart + u.QuadPart) * 100ULL);
}

void tc_free(int64_t h)
{
  if (h != 0) CloseHandle((HANDLE)(intptr_t)h);
}

#elif defined(__APPLE__)

/*  M5 VARIANT -- ONLY the macOS branch differs from threadcpu.c.  tc_self takes
    a SEND right on the thread's port so the name stays owned by us after the
    thread has exited (and therefore cannot be recycled for another thread);
    tc_free gives it back with mach_port_deallocate.  tc_free_rc is an EXTRA
    export, present only in this variant, so the probe can see the
    mach_port_deallocate return code that tc_free's void signature hides.   */

#include <pthread.h>
#include <mach/mach.h>

int64_t tc_self(void)
{
  mach_port_t port = pthread_mach_thread_np(pthread_self());
  if (port == MACH_PORT_NULL) return 0;
  if (mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_SEND, 1)
        != KERN_SUCCESS)
    return 0;
  return (int64_t)port;
}

int64_t tc_read(int64_t h)
{
  thread_basic_info_data_t info;
  mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
  if (h == 0) return -1;
  if (thread_info((thread_act_t)h, THREAD_BASIC_INFO,
                  (thread_info_t)&info, &count) != KERN_SUCCESS)
    return -1;
  return (int64_t)(info.user_time.seconds + info.system_time.seconds) * 1000000000LL
       + (int64_t)(info.user_time.microseconds + info.system_time.microseconds) * 1000LL;
}

int64_t tc_free_rc(int64_t h)
{
  if (h == 0) return (int64_t)KERN_SUCCESS;
  return (int64_t)mach_port_deallocate(mach_task_self(), (mach_port_t)h);
}

void tc_free(int64_t h) { (void)tc_free_rc(h); }

#else  /* Linux and other POSIX with per-thread CPU clocks */

#include <pthread.h>
#include <time.h>

int64_t tc_self(void)
{
  clockid_t cid;
  if (pthread_getcpuclockid(pthread_self(), &cid) != 0) return 0;
  /* A thread CPU clockid is never 0 (that is CLOCK_REALTIME), so 0 is free to
     mean failure. */
  return (int64_t)cid;
}

int64_t tc_read(int64_t h)
{
  struct timespec ts;
  if (h == 0) return -1;
  if (clock_gettime((clockid_t)h, &ts) != 0) return -1;   /* EINVAL once the thread is gone */
  return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

void tc_free(int64_t h) { (void)h; }

#endif
