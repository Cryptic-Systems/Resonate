/**
 * Sample-rate conversion — TU for linkage; hot path is in resampler.h.
 */
#include "core/resampler.h"

#include <vector>

namespace dsp {

void make_sinc_kernel(std::vector<float>& kernel, int taps, float cutoff) {
    if (taps < 3) taps = 3;
    if ((taps & 1) == 0) ++taps;
    kernel.resize(static_cast<size_t>(taps));
    int mid = taps / 2;
    double sum = 0.0;
    for (int i = 0; i < taps; ++i) {
        double x = i - mid;
        double sinc = (x == 0.0) ? 1.0 : std::sin(M_PI * cutoff * x) / (M_PI * x);
        double w = 0.42 - 0.5 * std::cos(2.0 * M_PI * i / (taps - 1))
                        + 0.08 * std::cos(4.0 * M_PI * i / (taps - 1));
        kernel[static_cast<size_t>(i)] = static_cast<float>(sinc * w);
        sum += kernel[static_cast<size_t>(i)];
    }
    if (sum != 0.0) {
        for (float& v : kernel) v = static_cast<float>(v / sum);
    }
}

} // namespace dsp
