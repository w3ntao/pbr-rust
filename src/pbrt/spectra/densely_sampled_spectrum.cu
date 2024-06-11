#include "pbrt/spectra/densely_sampled_spectrum.h"
#include "pbrt/base/spectrum.h"

PBRT_CPU_GPU
FloatType DenselySampledSpectrum::inner_product(const Spectrum *spectrum) const {
    FloatType sum = 0;
    for (int lambda = LAMBDA_MIN; lambda <= LAMBDA_MAX; ++lambda) {
        sum += (*this)(lambda) * (*spectrum)(lambda);
    }

    return sum;
}

PBRT_CPU_GPU
void DenselySampledSpectrum::init_from_spectrum(const Spectrum *spectrum) {
    for (int lambda = LAMBDA_MIN; lambda <= LAMBDA_MAX; ++lambda) {
        values[lambda - LAMBDA_MIN] = (*spectrum)(lambda);
    }
}
