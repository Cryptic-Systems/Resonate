/**
 * Real-time / near-real-time thread priority helpers
 */

#include "dsp_engine.h"
#include <cstring>

#if defined(_WIN32)
  #include <windows.h>
#elif defined(__linux__) || defined(__ANDROID__)
  #include <pthread.h>
  #include <sched.h>
  #include <sys/resource.h>
#elif defined(__APPLE__)
  #include <pthread.h>
  #include <mach/mach.h>
  #include <mach/thread_policy.h>
#endif

extern "C" {

DSP_API int dsp_set_realtime_priority(DspEngine* /*engine*/, int priority)
{
    if (priority <= 0) return 1; // nothing to do

#if defined(_WIN32)
    // Windows: TIME_CRITICAL is the highest
    HANDLE h = GetCurrentThread();
    return SetThreadPriority(h, THREAD_PRIORITY_TIME_CRITICAL) != 0 ? 1 : 0;

#elif defined(__linux__) || defined(__ANDROID__)
    // Prefer SCHED_FIFO when possible (requires CAP_SYS_NICE or root)
    struct sched_param param;
    std::memset(&param, 0, sizeof(param));
    param.sched_priority = priority > 99 ? 99 : priority;

    if (pthread_setschedparam(pthread_self(), SCHED_FIFO, &param) == 0)
        return 1;

    // Fallback: nice value
    return setpriority(PRIO_PROCESS, 0, -20) == 0 ? 1 : 0;

#elif defined(__APPLE__)
    // macOS / iOS: use thread time constraint policy for real-time
    thread_time_constraint_policy_data_t policy;
    policy.period      = 0;
    policy.computation = 50000;   // 50 µs (tune later)
    policy.constraint  = 100000;  // 100 µs
    policy.preemptible = 1;

    kern_return_t kr = thread_policy_set(
        pthread_mach_thread_np(pthread_self()),
        THREAD_TIME_CONSTRAINT_POLICY,
        (thread_policy_t)&policy,
        THREAD_TIME_CONSTRAINT_POLICY_COUNT);

    return kr == KERN_SUCCESS ? 1 : 0;

#else
    (void)priority;
    return 0; // unsupported platform
#endif
}

} // extern "C"
