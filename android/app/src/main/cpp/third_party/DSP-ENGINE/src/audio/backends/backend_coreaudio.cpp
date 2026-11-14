/**
 * macOS / iOS Core Audio backend — matches IAudioBackend in backend.h
 */
#include "audio/backends/backend.h"

#if defined(DSP_HAS_COREAUDIO) && (defined(__APPLE__) || defined(__MACH__))

#include <TargetConditionals.h>
#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>
#include <CoreAudio/CoreAudioTypes.h>
#include <atomic>
#include <cstring>
#include <mutex>

namespace dsp {

class CoreAudioBackend final : public IAudioBackend {
public:
    CoreAudioBackend() = default;
    ~CoreAudioBackend() override { close(); }

    DspError open(const BackendConfig& cfg) override {
        close();

        AudioComponentDescription desc{};
        desc.componentType = kAudioUnitType_Output;
#if TARGET_OS_IPHONE
        desc.componentSubType = kAudioUnitSubType_RemoteIO;
#else
        desc.componentSubType = kAudioUnitSubType_DefaultOutput;
#endif
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;

        AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
        if (!comp) return DSP_ERR_DEVICE;

        OSStatus st = AudioComponentInstanceNew(comp, &unit_);
        if (st != noErr || !unit_) return DSP_ERR_DEVICE;

        UInt32 flag = 1;
        st = AudioUnitSetProperty(unit_, kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Output, 0, &flag, sizeof(flag));
        if (st != noErr) { close(); return DSP_ERR_DEVICE; }

        AudioStreamBasicDescription asbd{};
        asbd.mSampleRate       = cfg.sample_rate;
        asbd.mFormatID         = kAudioFormatLinearPCM;
        asbd.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        asbd.mBytesPerPacket   = sizeof(float) * static_cast<UInt32>(cfg.channels);
        asbd.mFramesPerPacket  = 1;
        asbd.mBytesPerFrame    = asbd.mBytesPerPacket;
        asbd.mChannelsPerFrame = static_cast<UInt32>(cfg.channels);
        asbd.mBitsPerChannel   = 32;

        st = AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input, 0, &asbd, sizeof(asbd));
        if (st != noErr) { close(); return DSP_ERR_DEVICE; }

        AURenderCallbackStruct cb{};
        cb.inputProc = &CoreAudioBackend::render_callback;
        cb.inputProcRefCon = this;
        st = AudioUnitSetProperty(unit_, kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input, 0, &cb, sizeof(cb));
        if (st != noErr) { close(); return DSP_ERR_DEVICE; }

        UInt32 frames = static_cast<UInt32>(cfg.buffer_frames);
        AudioUnitSetProperty(unit_, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &frames, sizeof(frames));

        st = AudioUnitInitialize(unit_);
        if (st != noErr) { close(); return DSP_ERR_DEVICE; }

        rate_   = cfg.sample_rate;
        ch_     = cfg.channels;
        frames_ = cfg.buffer_frames;
        opened_ = true;
        xruns_.store(0, std::memory_order_relaxed);
        return DSP_OK;
    }

    void close() override {
        stop();
        if (unit_) {
            AudioUnitUninitialize(unit_);
            AudioComponentInstanceDispose(unit_);
            unit_ = nullptr;
        }
        opened_ = false;
    }

    DspError start() override {
        if (!opened_ || !unit_) return DSP_ERR_DEVICE;
        if (running_.load(std::memory_order_acquire)) return DSP_ERR_ALREADY_RUNNING;
        if (AudioOutputUnitStart(unit_) != noErr) return DSP_ERR_DEVICE;
        running_.store(true, std::memory_order_release);
        return DSP_OK;
    }

    DspError stop() override {
        if (!unit_ || !running_.load(std::memory_order_acquire)) return DSP_OK;
        AudioOutputUnitStop(unit_);
        running_.store(false, std::memory_order_release);
        return DSP_OK;
    }

    bool is_running() const override { return running_.load(std::memory_order_acquire); }
    const char* name() const override { return "coreaudio"; }
    int32_t sample_rate() const override { return rate_; }
    int32_t channels() const override { return ch_; }
    int32_t buffer_frames() const override { return frames_; }
    uint32_t xrun_count() const override {
        return static_cast<uint32_t>(xruns_.load(std::memory_order_relaxed));
    }

    void set_render_callback(BackendRenderFn fn, void* user) override {
        std::lock_guard<std::mutex> lock(cb_mutex_);
        render_ = fn;
        user_ = user;
    }

private:
    static OSStatus render_callback(void* inRefCon,
                                    AudioUnitRenderActionFlags*,
                                    const AudioTimeStamp*,
                                    UInt32, UInt32 inNumberFrames,
                                    AudioBufferList* ioData)
    {
        auto* self = static_cast<CoreAudioBackend*>(inRefCon);
        if (!ioData || ioData->mNumberBuffers == 0) return noErr;

        float* out = static_cast<float*>(ioData->mBuffers[0].mData);
        int32_t frames = static_cast<int32_t>(inNumberFrames);

        BackendRenderFn cb = nullptr;
        void* u = nullptr;
        {
            std::lock_guard<std::mutex> lock(self->cb_mutex_);
            cb = self->render_;
            u = self->user_;
        }
        if (cb)
            cb(out, frames, self->ch_, u);
        else
            std::memset(out, 0, static_cast<size_t>(frames * self->ch_) * sizeof(float));
        return noErr;
    }

    AudioUnit unit_ = nullptr;
    std::atomic<bool> running_{false};
    std::atomic<int> xruns_{0};
    bool opened_ = false;
    int32_t rate_ = 0, ch_ = 0, frames_ = 0;
    BackendRenderFn render_ = nullptr;
    void* user_ = nullptr;
    std::mutex cb_mutex_;
};

IAudioBackend* create_coreaudio_backend() {
    return new (std::nothrow) CoreAudioBackend();
}

} // namespace dsp

#else

namespace dsp {
IAudioBackend* create_coreaudio_backend() { return nullptr; }
} // namespace dsp

#endif
