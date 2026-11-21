/**
 * Lock-free SPSC ring buffer implementation.
 */

#include "audio/ring_buffer.h"
#include <algorithm>
#include <cstring>

namespace dsp {

RingBuffer::RingBuffer(size_t capacity_frames, int channels)
    : capacity_(capacity_frames < 2 ? 2 : capacity_frames)
    , channels_(channels < 1 ? 1 : channels)
    , data_(capacity_ * static_cast<size_t>(channels_), 0.f)
{
}

size_t RingBuffer::write(const float* interleaved, size_t frames) {
    if (!interleaved || frames == 0) return 0;

    size_t w = write_pos_.load(std::memory_order_relaxed);
    size_t r = read_pos_.load(std::memory_order_acquire);
    size_t avail = (r + capacity_ - w - 1) % capacity_;
    size_t n = std::min(frames, avail);
    if (n == 0) return 0;

    size_t first = std::min(n, capacity_ - w);
    std::memcpy(data_.data() + w * static_cast<size_t>(channels_), interleaved,
                first * static_cast<size_t>(channels_) * sizeof(float));
    if (n > first) {
        std::memcpy(data_.data(), interleaved + first * static_cast<size_t>(channels_),
                    (n - first) * static_cast<size_t>(channels_) * sizeof(float));
    }
    write_pos_.store((w + n) % capacity_, std::memory_order_release);
    return n;
}

size_t RingBuffer::read(float* interleaved, size_t frames) {
    if (!interleaved || frames == 0) return 0;

    size_t r = read_pos_.load(std::memory_order_relaxed);
    size_t w = write_pos_.load(std::memory_order_acquire);
    size_t avail = (w + capacity_ - r) % capacity_;
    size_t n = std::min(frames, avail);
    if (n == 0) return 0;

    size_t first = std::min(n, capacity_ - r);
    std::memcpy(interleaved, data_.data() + r * static_cast<size_t>(channels_),
                first * static_cast<size_t>(channels_) * sizeof(float));
    if (n > first) {
        std::memcpy(interleaved + first * static_cast<size_t>(channels_), data_.data(),
                    (n - first) * static_cast<size_t>(channels_) * sizeof(float));
    }
    read_pos_.store((r + n) % capacity_, std::memory_order_release);
    return n;
}

size_t RingBuffer::available_read() const {
    size_t r = read_pos_.load(std::memory_order_relaxed);
    size_t w = write_pos_.load(std::memory_order_acquire);
    return (w + capacity_ - r) % capacity_;
}

size_t RingBuffer::available_write() const {
    size_t w = write_pos_.load(std::memory_order_relaxed);
    size_t r = read_pos_.load(std::memory_order_acquire);
    return (r + capacity_ - w - 1) % capacity_;
}

void RingBuffer::clear() {
    read_pos_.store(0, std::memory_order_relaxed);
    write_pos_.store(0, std::memory_order_relaxed);
    std::fill(data_.begin(), data_.end(), 0.f);
}

} // namespace dsp
