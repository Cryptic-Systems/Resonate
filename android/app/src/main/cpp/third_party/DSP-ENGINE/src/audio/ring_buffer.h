/**
 * Lock-free single-producer single-consumer ring buffer.
 */
#ifndef DSP_RING_BUFFER_H
#define DSP_RING_BUFFER_H

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace dsp {

class RingBuffer {
public:
    explicit RingBuffer(size_t capacity_frames, int channels);
    ~RingBuffer() = default;

    RingBuffer(const RingBuffer&) = delete;
    RingBuffer& operator=(const RingBuffer&) = delete;

    size_t capacity() const { return capacity_; }
    int channels() const { return channels_; }

    size_t write(const float* interleaved, size_t frames);
    size_t read(float* interleaved, size_t frames);

    size_t available_read() const;
    size_t available_write() const;

    void clear();

private:
    size_t capacity_;
    int channels_;
    std::vector<float> data_;
    std::atomic<size_t> write_pos_{0};
    std::atomic<size_t> read_pos_{0};
};

} // namespace dsp

#endif
