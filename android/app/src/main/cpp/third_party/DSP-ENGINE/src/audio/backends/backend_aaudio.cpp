/**
 * Android AAudio output backend — matches IAudioBackend in backend.h
 */
#include "audio/backends/backend.h"

#if defined(DSP_HAS_AAUDIO) && defined(__ANDROID__)

#include <aaudio/AAudio.h>
#include <android/log.h>
#include <atomic>
#include <cstring>
#include <mutex>

#define AA_LOG(...) __android_log_print(ANDROID_LOG_INFO, "DSP-AAudio", __VA_ARGS__)
#define AA_ERR(...) __android_log_print(ANDROID_LOG_ERROR, "DSP-AAudio", __VA_ARGS__)

namespace dsp {

class AAudioBackend final : public IAudioBackend {
public:
    AAudioBackend() = default;
    ~AAudioBackend() override { close(); }

    DspError open(const BackendConfig& cfg) override {
        close();
        AAudioStreamBuilder* builder = nullptr;
        aaudio_result_t res = AAudio_createStreamBuilder(&builder);
        if (res != AAUDIO_OK || !builder) {
            AA_ERR("createStreamBuilder failed: %s", AAudio_convertResultToText(res));
            return DSP_ERR_DEVICE;
        }

        AAudioStreamBuilder_setDirection(builder, AAUDIO_DIRECTION_OUTPUT);
        AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_FLOAT);
        AAudioStreamBuilder_setChannelCount(builder, cfg.channels);
        AAudioStreamBuilder_setSampleRate(builder, cfg.sample_rate);
        AAudioStreamBuilder_setDataCallback(builder, &AAudioBackend::data_callback, this);
        AAudioStreamBuilder_setErrorCallback(builder, &AAudioBackend::error_callback, this);
        AAudioStreamBuilder_setFramesPerDataCallback(builder, cfg.buffer_frames);
        AAudioStreamBuilder_setPerformanceMode(builder, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
        AAudioStreamBuilder_setSharingMode(builder,
            cfg.exclusive ? AAUDIO_SHARING_MODE_EXCLUSIVE : AAUDIO_SHARING_MODE_SHARED);
        if (cfg.device_id > 0)
            AAudioStreamBuilder_setDeviceId(builder, cfg.device_id);
#if __ANDROID_API__ >= 28
        AAudioStreamBuilder_setUsage(builder, AAUDIO_USAGE_MEDIA);
        AAudioStreamBuilder_setContentType(builder, AAUDIO_CONTENT_TYPE_MUSIC);
#endif

        AAudioStream* stream = nullptr;
        res = AAudioStreamBuilder_openStream(builder, &stream);
        AAudioStreamBuilder_delete(builder);
        if (res != AAUDIO_OK || !stream) {
            if (cfg.exclusive) {
                BackendConfig shared = cfg;
                shared.exclusive = false;
                return open(shared);
            }
            AA_ERR("openStream failed: %s", AAudio_convertResultToText(res));
            return DSP_ERR_DEVICE;
        }

        stream_ = stream;
        rate_   = AAudioStream_getSampleRate(stream_);
        ch_     = AAudioStream_getChannelCount(stream_);
        frames_ = AAudioStream_getFramesPerBurst(stream_);
        if (frames_ <= 0) frames_ = cfg.buffer_frames;

        int32_t buf_cap = AAudioStream_getBufferCapacityInFrames(stream_);
        int32_t target = frames_ * 2;
        if (target > buf_cap) target = buf_cap;
        AAudioStream_setBufferSizeInFrames(stream_, target);

        xruns_.store(0, std::memory_order_relaxed);
        opened_ = true;
        return DSP_OK;
    }

    void close() override {
        stop();
        if (stream_) {
            AAudioStream_close(stream_);
            stream_ = nullptr;
        }
        opened_ = false;
    }

    DspError start() override {
        if (!opened_ || !stream_) return DSP_ERR_DEVICE;
        if (running_.load(std::memory_order_acquire)) return DSP_ERR_ALREADY_RUNNING;
        aaudio_result_t res = AAudioStream_requestStart(stream_);
        if (res != AAUDIO_OK) return DSP_ERR_DEVICE;
        running_.store(true, std::memory_order_release);
        return DSP_OK;
    }

    DspError stop() override {
        if (!stream_ || !running_.load(std::memory_order_acquire)) return DSP_OK;
        AAudioStream_requestStop(stream_);
        running_.store(false, std::memory_order_release);
        return DSP_OK;
    }

    bool is_running() const override { return running_.load(std::memory_order_acquire); }
    const char* name() const override { return "aaudio"; }
    int32_t sample_rate() const override { return rate_; }
    int32_t channels() const override { return ch_; }
    int32_t buffer_frames() const override { return frames_; }
    uint32_t xrun_count() const override { return static_cast<uint32_t>(xruns_.load(std::memory_order_relaxed)); }

    void set_render_callback(BackendRenderFn fn, void* user) override {
        std::lock_guard<std::mutex> lock(cb_mutex_);
        render_ = fn;
        user_ = user;
    }

private:
    static aaudio_data_callback_result_t data_callback(
        AAudioStream*, void* user, void* audioData, int32_t numFrames)
    {
        auto* self = static_cast<AAudioBackend*>(user);
        float* out = static_cast<float*>(audioData);
        BackendRenderFn cb = nullptr;
        void* u = nullptr;
        {
            std::lock_guard<std::mutex> lock(self->cb_mutex_);
            cb = self->render_;
            u = self->user_;
        }
        if (cb)
            cb(out, numFrames, self->ch_, u);
        else
            std::memset(out, 0, static_cast<size_t>(numFrames * self->ch_) * sizeof(float));
        return AAUDIO_CALLBACK_RESULT_CONTINUE;
    }

    static void error_callback(AAudioStream*, void* user, aaudio_result_t error) {
        auto* self = static_cast<AAudioBackend*>(user);
        AA_ERR("error: %s", AAudio_convertResultToText(error));
        if (error == AAUDIO_ERROR_DISCONNECTED || error == AAUDIO_ERROR_TIMEOUT)
            self->xruns_.fetch_add(1, std::memory_order_relaxed);
    }

    AAudioStream* stream_ = nullptr;
    std::atomic<bool> running_{false};
    std::atomic<int> xruns_{0};
    bool opened_ = false;
    int32_t rate_ = 0, ch_ = 0, frames_ = 0;
    BackendRenderFn render_ = nullptr;
    void* user_ = nullptr;
    std::mutex cb_mutex_;
};

IAudioBackend* create_aaudio_backend() {
    return new (std::nothrow) AAudioBackend();
}

} // namespace dsp

#else

namespace dsp {
IAudioBackend* create_aaudio_backend() { return nullptr; }
} // namespace dsp

#endif
