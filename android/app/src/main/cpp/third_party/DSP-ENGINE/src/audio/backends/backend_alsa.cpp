/**
 * Linux ALSA playback backend (optional, DSP_HAS_ALSA).
 */
#include "audio/backends/backend.h"

#if defined(DSP_HAS_ALSA) && (defined(__linux__) || defined(__ANDROID__))

#include <alsa/asoundlib.h>
#include <atomic>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

namespace dsp {

class AlsaBackend : public IAudioBackend {
public:
    ~AlsaBackend() override { close(); }

    DspError open(const BackendConfig& cfg) override {
        close();
        snd_pcm_t* pcm = nullptr;
        int err = snd_pcm_open(&pcm, "default", SND_PCM_STREAM_PLAYBACK, 0);
        if (err < 0 || !pcm) return DSP_ERR_DEVICE;

        snd_pcm_hw_params_t* hw = nullptr;
        snd_pcm_hw_params_alloca(&hw);
        snd_pcm_hw_params_any(pcm, hw);
        snd_pcm_hw_params_set_access(pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED);
        snd_pcm_hw_params_set_format(pcm, hw, SND_PCM_FORMAT_FLOAT_LE);
        unsigned int rate = static_cast<unsigned int>(cfg.sample_rate);
        snd_pcm_hw_params_set_rate_near(pcm, hw, &rate, nullptr);
        snd_pcm_hw_params_set_channels(pcm, hw, static_cast<unsigned int>(cfg.channels));
        snd_pcm_uframes_t period = static_cast<snd_pcm_uframes_t>(cfg.buffer_frames);
        snd_pcm_hw_params_set_period_size_near(pcm, hw, &period, nullptr);
        snd_pcm_uframes_t buffer = period * 4;
        snd_pcm_hw_params_set_buffer_size_near(pcm, hw, &buffer);

        err = snd_pcm_hw_params(pcm, hw);
        if (err < 0) {
            snd_pcm_close(pcm);
            return DSP_ERR_DEVICE;
        }

        pcm_ = pcm;
        rate_ = static_cast<int32_t>(rate);
        ch_ = cfg.channels;
        frames_ = static_cast<int32_t>(period);
        opened_ = true;
        xruns_.store(0, std::memory_order_relaxed);
        return DSP_OK;
    }

    void close() override {
        stop();
        if (pcm_) {
            snd_pcm_close(pcm_);
            pcm_ = nullptr;
        }
        opened_ = false;
    }

    DspError start() override {
        if (!opened_ || !pcm_) return DSP_ERR_DEVICE;
        if (running_.load(std::memory_order_acquire)) return DSP_ERR_ALREADY_RUNNING;
        running_.store(true, std::memory_order_release);
        thread_ = std::thread(&AlsaBackend::render_thread, this);
        return DSP_OK;
    }

    DspError stop() override {
        if (!running_.load(std::memory_order_acquire)) return DSP_OK;
        running_.store(false, std::memory_order_release);
        if (thread_.joinable()) thread_.join();
        if (pcm_) snd_pcm_drop(pcm_);
        return DSP_OK;
    }

    bool is_running() const override { return running_.load(std::memory_order_acquire); }
    const char* name() const override { return "alsa"; }
    int32_t sample_rate() const override { return rate_; }
    int32_t channels() const override { return ch_; }
    int32_t buffer_frames() const override { return frames_; }
    uint32_t xrun_count() const override {
        return static_cast<uint32_t>(xruns_.load(std::memory_order_relaxed));
    }

    void set_render_callback(BackendRenderFn fn, void* user) override {
        std::lock_guard<std::mutex> lock(cb_mutex_);
        render_fn_ = fn;
        user_ = user;
    }

private:
    void render_thread() {
        std::vector<float> buf(static_cast<size_t>(frames_ * ch_));
        while (running_.load(std::memory_order_acquire)) {
            BackendRenderFn cb = nullptr;
            void* u = nullptr;
            {
                std::lock_guard<std::mutex> lock(cb_mutex_);
                cb = render_fn_;
                u = user_;
            }
            if (cb)
                cb(buf.data(), frames_, ch_, u);
            else
                std::memset(buf.data(), 0, buf.size() * sizeof(float));

            float* p = buf.data();
            snd_pcm_uframes_t left = static_cast<snd_pcm_uframes_t>(frames_);
            while (left > 0 && running_.load(std::memory_order_acquire)) {
                snd_pcm_sframes_t n = snd_pcm_writei(pcm_, p, left);
                if (n == -EPIPE) {
                    xruns_.fetch_add(1, std::memory_order_relaxed);
                    snd_pcm_prepare(pcm_);
                    continue;
                }
                if (n < 0) {
                    xruns_.fetch_add(1, std::memory_order_relaxed);
                    break;
                }
                p += n * ch_;
                left -= static_cast<snd_pcm_uframes_t>(n);
            }
        }
    }

    snd_pcm_t* pcm_ = nullptr;
    std::thread thread_;
    std::atomic<bool> running_{false};
    std::atomic<int> xruns_{0};
    bool opened_ = false;
    int32_t rate_ = 0, ch_ = 0, frames_ = 0;
    BackendRenderFn render_fn_ = nullptr;
    void* user_ = nullptr;
    std::mutex cb_mutex_;
};

IAudioBackend* create_alsa_backend() {
    return new (std::nothrow) AlsaBackend();
}

} // namespace dsp

#else

namespace dsp {
IAudioBackend* create_alsa_backend() { return nullptr; }
} // namespace dsp

#endif
