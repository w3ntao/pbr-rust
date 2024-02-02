#pragma once

#include "pbrt/spectra/xyz.h"

class SampledSpectrum {
  public:
    PBRT_CPU_GPU explicit SampledSpectrum(const std::array<double, NSpectrumSamples> _values)
        : values(_values) {}

    PBRT_CPU_GPU
    explicit SampledSpectrum(double c) {
        values.fill(c);
    }

    PBRT_CPU_GPU
    double operator[](int i) const {
        return values[i];
    }

    PBRT_CPU_GPU
    double &operator[](int i) {
        return values[i];
    }

    PBRT_CPU_GPU
    SampledSpectrum operator+(const SampledSpectrum &s) const {
        std::array<double, NSpectrumSamples> sum;
        for (int i = 0; i < NSpectrumSamples; ++i) {
            sum[i] = values[i] + s.values[i];
        }

        return SampledSpectrum(sum);
    }

    PBRT_CPU_GPU
    void operator+=(const SampledSpectrum &s) {
        *this = *this + s;
    }

    PBRT_CPU_GPU
    SampledSpectrum operator-(const SampledSpectrum &s) const {
        std::array<double, NSpectrumSamples> difference;
        for (int i = 0; i < NSpectrumSamples; ++i) {
            difference[i] = values[i] - s.values[i];
        }

        return SampledSpectrum(difference);
    }

    PBRT_CPU_GPU
    void operator-=(const SampledSpectrum &s) {
        *this = *this - s;
    }

    PBRT_CPU_GPU
    SampledSpectrum operator*(const SampledSpectrum &s) const {
        std::array<double, NSpectrumSamples> product;
        for (int i = 0; i < NSpectrumSamples; ++i) {
            product[i] = values[i] * s.values[i];
        }

        return SampledSpectrum(product);
    }

    PBRT_CPU_GPU
    SampledSpectrum operator*(double a) const {
        std::array<double, NSpectrumSamples> product;
        for (int i = 0; i < NSpectrumSamples; ++i) {
            product[i] = values[i] * a;
        }

        return SampledSpectrum(product);
    }

    PBRT_CPU_GPU
    friend SampledSpectrum operator*(double a, const SampledSpectrum &s) {
        return s * a;
    }

    PBRT_CPU_GPU
    void operator*=(const SampledSpectrum &s) {
        *this = *this * s;
    }

    PBRT_CPU_GPU
    void operator*=(double a) {
        *this = *this * a;
    }

    PBRT_CPU_GPU
    SampledSpectrum operator/(const SampledSpectrum &s) const {
        std::array<double, NSpectrumSamples> quotient;
        for (int i = 0; i < NSpectrumSamples; ++i) {
            quotient[i] = values[i] / s.values[i];
        }

        return SampledSpectrum(quotient);
    }

    PBRT_CPU_GPU
    SampledSpectrum operator/(double a) const {
        std::array<double, NSpectrumSamples> quotient;
        for (int i = 0; i < NSpectrumSamples; ++i) {
            quotient[i] = values[i] / a;
        }

        return SampledSpectrum(quotient);
    }

    PBRT_CPU_GPU
    void operator/=(const SampledSpectrum &s) {
        *this = *this / s;
    }

    PBRT_CPU_GPU
    void operator/=(double a) {
        *this = *this / a;
    }

    PBRT_CPU_GPU
    SampledSpectrum operator-() const {
        std::array<double, NSpectrumSamples> ret;
        for (int i = 0; i < NSpectrumSamples; ++i) {
            ret[i] = -values[i];
        }

        return SampledSpectrum(ret);
    }

    PBRT_CPU_GPU
    bool operator==(const SampledSpectrum &s) const {
        return values == s.values;
    }

    PBRT_CPU_GPU
    bool operator!=(const SampledSpectrum &s) const {
        return values != s.values;
    }

    // TODO: progress 2024/02/03: implementing XYZ, blocked by DenselySampledSpectrum
    /*
    PBRT_CPU_GPU
    XYZ ToXYZ(const SampledWavelengths &lambda) const;
    PBRT_CPU_GPU
    RGB ToRGB(const SampledWavelengths &lambda, const RGBColorSpace &cs) const;
    PBRT_CPU_GPU
    Float y(const SampledWavelengths &lambda) const;
    */

    PBRT_CPU_GPU
    bool is_positive() const {
        for (int i = 0; i < NSpectrumSamples; ++i) {
            if (values[i] > 0) {
                return true;
            }
        }

        return false;
    }

    PBRT_CPU_GPU
    double min_component_value() const {
        double m = values[0];
        for (int i = 1; i < NSpectrumSamples; ++i) {
            m = std::min(m, values[i]);
        }

        return m;
    }

    PBRT_CPU_GPU
    double max_component_value() const {
        double m = values[0];
        for (int i = 1; i < NSpectrumSamples; ++i) {
            m = std::max(m, values[i]);
        }
        return m;
    }

    PBRT_CPU_GPU
    double average() const {
        double sum = values[0];
        for (int i = 1; i < NSpectrumSamples; ++i) {
            sum += values[i];
        }

        return sum / NSpectrumSamples;
    }

  private:
    std::array<double, NSpectrumSamples> values;
};
