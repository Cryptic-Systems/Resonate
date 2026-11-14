/**
 * Shared audio backend interface and NullBackend.
 */
#pragma once

#include "dsp_engine.h"
#include <cstdint>

namespace dsp {

struct BackendConfig {
    int32_t sample_rate   = 48000;
    int32_t channels      = 2;
    int32_t buffer_frames = 256;
    bool    exclusive     = true;
    int32_t device_id     = 0;
};

/** Render callback: interleaved float32, channels from backend. */
using BackendRenderFn = void (*)(float* out, int32_t frames, int32_t channels, void* user);

class IAudioBackend {
public:
    virtual ~IAudioBackend() = default;

    virtual DspError open(const BackendConfig& cfg) = 0;
    virtual void     close() = 0;
    virtual DspError start() = 0;
    virtual DspError stop() = 0;

    virtual bool is_running() const = 0;
    virtual const char* name() const = 0;

    virtual int32_t sample_rate() const = 0;
    virtual int32_t channels() const = 0;
    virtual int32_t buffer_frames() const = 0;
    virtual uint32_t xrun_count() const { return 0; }

    virtual void set_render_callback(BackendRenderFn fn, void* user) = 0;
};

/**
 * Null backend — no device I/O (offline / unit tests / hosts without a driver).
 * open() succeeds for lifecycle tests; start() returns DSP_ERR_UNSUPPORTED
 * so callers never believe audio is playing.
 */
class NullBackend : public IAudioBackend {
public:
    DspError open(const BackendConfig& cfg) override {
        cfg_ = cfg;
        opened_ = true;
        return DSP_OK;
    }
    void close() override { opened_ = false; running_ = false; }
    DspError start() override {
        (void)opened_;
        return DSP_ERR_UNSUPPORTED;
    }
    DspError stop() override { running_ = false; return DSP_OK; }
    bool is_running() const override { return false; }
    const char* name() const override { return "null"; }
    int32_t sample_rate() const override { return cfg_.sample_rate; }
    int32_t channels() const override { return cfg_.channels; }
    int32_t buffer_frames() const override { return cfg_.buffer_frames; }
    void set_render_callback(BackendRenderFn fn, void* user) override {
        render_ = fn;
        user_ = user;
    }
private:
    BackendConfig cfg_{};
    bool opened_ = false;
    bool running_ = false;
    BackendRenderFn render_ = nullptr;
    void* user_ = nullptr;
};

IAudioBackend* create_aaudio_backend();
IAudioBackend* create_wasapi_backend();
IAudioBackend* create_coreaudio_backend();
IAudioBackend* create_alsa_backend();
IAudioBackend* create_default_backend();

} // namespace dsp
