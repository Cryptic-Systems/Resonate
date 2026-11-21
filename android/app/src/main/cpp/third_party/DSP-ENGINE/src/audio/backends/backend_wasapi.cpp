/**
 * Windows WASAPI backend — matches IAudioBackend in backend.h
 */
#include "audio/backends/backend.h"

#if defined(DSP_HAS_WASAPI) && defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define INITGUID
#include <windows.h>
#include <objbase.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <avrt.h>
#include <mmreg.h>
#include <atomic>
#include <cstring>
#include <mutex>
#include <thread>

#ifndef SPEAKER_FRONT_LEFT
#define SPEAKER_FRONT_LEFT   0x1
#define SPEAKER_FRONT_RIGHT  0x2
#define SPEAKER_FRONT_CENTER 0x4
#endif
#ifndef KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
static const GUID KSDATAFORMAT_SUBTYPE_IEEE_FLOAT = {
    0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}
};
#endif

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "avrt.lib")

namespace dsp {

class WasapiBackend final : public IAudioBackend {
public:
    WasapiBackend() = default;
    ~WasapiBackend() override { close(); }

    DspError open(const BackendConfig& cfg) override {
        close();
        HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (FAILED(hr) && hr != RPC_E_CHANGED_MODE && hr != S_FALSE)
            return DSP_ERR_DEVICE;
        /* S_OK = we own a COM init on this thread; S_FALSE/CHANGED_MODE = already inited. */
        com_inited_ = (hr == S_OK);

        IMMDeviceEnumerator* enumerator = nullptr;
        hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                              __uuidof(IMMDeviceEnumerator), (void**)&enumerator);
        if (FAILED(hr) || !enumerator) return DSP_ERR_DEVICE;

        IMMDevice* device = nullptr;
        hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
        enumerator->Release();
        if (FAILED(hr) || !device) return DSP_ERR_DEVICE;

        IAudioClient* client = nullptr;
        hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&client);
        device->Release();
        if (FAILED(hr) || !client) return DSP_ERR_DEVICE;

        WAVEFORMATEXTENSIBLE wfx{};
        wfx.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
        wfx.Format.nChannels = static_cast<WORD>(cfg.channels);
        wfx.Format.nSamplesPerSec = static_cast<DWORD>(cfg.sample_rate);
        wfx.Format.wBitsPerSample = 32;
        wfx.Format.nBlockAlign = (wfx.Format.nChannels * wfx.Format.wBitsPerSample) / 8;
        wfx.Format.nAvgBytesPerSec = wfx.Format.nSamplesPerSec * wfx.Format.nBlockAlign;
        wfx.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
        wfx.Samples.wValidBitsPerSample = 32;
        wfx.dwChannelMask = (cfg.channels == 1) ? SPEAKER_FRONT_CENTER
                                                : (SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT);
        wfx.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;

        REFERENCE_TIME duration = static_cast<REFERENCE_TIME>(
            10000000.0 * cfg.buffer_frames / cfg.sample_rate);
        if (duration < 30000) duration = 30000;

        DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
        if (!cfg.exclusive)
            flags |= AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM;

        hr = client->Initialize(
            cfg.exclusive ? AUDCLNT_SHAREMODE_EXCLUSIVE : AUDCLNT_SHAREMODE_SHARED,
            flags, duration, cfg.exclusive ? duration : 0,
            (WAVEFORMATEX*)&wfx, nullptr);

        if (FAILED(hr) && cfg.exclusive) {
            flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM;
            hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, duration, 0,
                                    (WAVEFORMATEX*)&wfx, nullptr);
        }
        if (FAILED(hr)) {
            client->Release();
            return DSP_ERR_DEVICE;
        }

        event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!event_) { client->Release(); return DSP_ERR_DEVICE; }
        hr = client->SetEventHandle(event_);
        if (FAILED(hr)) {
            CloseHandle(event_); event_ = nullptr;
            client->Release();
            return DSP_ERR_DEVICE;
        }

        IAudioRenderClient* render = nullptr;
        hr = client->GetService(__uuidof(IAudioRenderClient), (void**)&render);
        if (FAILED(hr) || !render) {
            CloseHandle(event_); event_ = nullptr;
            client->Release();
            return DSP_ERR_DEVICE;
        }

        UINT32 bufferFrames = 0;
        client->GetBufferSize(&bufferFrames);

        client_ = client;
        render_ = render;
        rate_   = cfg.sample_rate;
        ch_     = cfg.channels;
        frames_ = static_cast<int32_t>(bufferFrames);
        opened_ = true;
        xruns_.store(0, std::memory_order_relaxed);
        return DSP_OK;
    }

    void close() override {
        stop();
        if (render_) { render_->Release(); render_ = nullptr; }
        if (client_) { client_->Release(); client_ = nullptr; }
        if (event_) { CloseHandle(event_); event_ = nullptr; }
        opened_ = false;
        if (com_inited_) {
            CoUninitialize();
            com_inited_ = false;
        }
    }

    DspError start() override {
        if (!opened_ || !client_) return DSP_ERR_DEVICE;
        if (running_.load(std::memory_order_acquire)) return DSP_ERR_ALREADY_RUNNING;

        UINT32 padding = 0;
        client_->GetCurrentPadding(&padding);
        UINT32 avail = static_cast<UINT32>(frames_) - padding;
        if (avail > 0) {
            BYTE* data = nullptr;
            if (SUCCEEDED(render_->GetBuffer(avail, &data)) && data) {
                std::memset(data, 0, avail * static_cast<UINT32>(ch_) * sizeof(float));
                render_->ReleaseBuffer(avail, 0);
            }
        }

        if (FAILED(client_->Start())) return DSP_ERR_DEVICE;
        running_.store(true, std::memory_order_release);
        thread_ = std::thread(&WasapiBackend::render_thread, this);
        return DSP_OK;
    }

    DspError stop() override {
        if (!running_.load(std::memory_order_acquire)) return DSP_OK;
        running_.store(false, std::memory_order_release);
        if (event_) SetEvent(event_);
        if (thread_.joinable()) thread_.join();
        if (client_) client_->Stop();
        return DSP_OK;
    }

    bool is_running() const override { return running_.load(std::memory_order_acquire); }
    const char* name() const override { return "wasapi"; }
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
        DWORD taskIndex = 0;
        HANDLE task = AvSetMmThreadCharacteristicsW(L"Pro Audio", &taskIndex);

        while (running_.load(std::memory_order_acquire)) {
            if (WaitForSingleObject(event_, 100) != WAIT_OBJECT_0) continue;

            UINT32 padding = 0;
            if (FAILED(client_->GetCurrentPadding(&padding))) {
                xruns_.fetch_add(1, std::memory_order_relaxed);
                continue;
            }
            UINT32 nframes = static_cast<UINT32>(frames_) - padding;
            if (nframes == 0) continue;

            BYTE* data = nullptr;
            if (FAILED(render_->GetBuffer(nframes, &data)) || !data) {
                xruns_.fetch_add(1, std::memory_order_relaxed);
                continue;
            }

            float* out = reinterpret_cast<float*>(data);
            BackendRenderFn cb = nullptr;
            void* u = nullptr;
            {
                std::lock_guard<std::mutex> lock(cb_mutex_);
                cb = render_fn_;
                u = user_;
            }
            if (cb)
                cb(out, static_cast<int32_t>(nframes), ch_, u);
            else
                std::memset(out, 0, nframes * static_cast<UINT32>(ch_) * sizeof(float));

            render_->ReleaseBuffer(nframes, 0);
        }

        if (task) AvRevertMmThreadCharacteristics(task);
    }

    IAudioClient* client_ = nullptr;
    IAudioRenderClient* render_ = nullptr;
    HANDLE event_ = nullptr;
    std::thread thread_;
    std::atomic<bool> running_{false};
    std::atomic<int> xruns_{0};
    bool opened_ = false;
    bool com_inited_ = false;
    int32_t rate_ = 0, ch_ = 0, frames_ = 0;
    BackendRenderFn render_fn_ = nullptr;
    void* user_ = nullptr;
    std::mutex cb_mutex_;
};

IAudioBackend* create_wasapi_backend() {
    return new (std::nothrow) WasapiBackend();
}

} // namespace dsp

#else

namespace dsp {
IAudioBackend* create_wasapi_backend() { return nullptr; }
} // namespace dsp

#endif
