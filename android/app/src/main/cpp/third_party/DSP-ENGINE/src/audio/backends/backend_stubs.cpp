/**
 * Backend factory — picks the best available backend for this platform.
 */
#include "audio/backends/backend.h"
#include <new>

namespace dsp {

IAudioBackend* create_default_backend()
{
#if defined(DSP_HAS_AAUDIO) && defined(__ANDROID__)
    if (IAudioBackend* b = create_aaudio_backend())
        return b;
#endif
#if defined(DSP_HAS_WASAPI) && defined(_WIN32)
    if (IAudioBackend* b = create_wasapi_backend())
        return b;
#endif
#if defined(DSP_HAS_COREAUDIO) && (defined(__APPLE__) || defined(__MACH__))
    if (IAudioBackend* b = create_coreaudio_backend())
        return b;
#endif
#if defined(DSP_HAS_ALSA) && (defined(__linux__) || defined(__ANDROID__))
    if (IAudioBackend* b = create_alsa_backend())
        return b;
#endif
    return new (std::nothrow) NullBackend();
}

} // namespace dsp
