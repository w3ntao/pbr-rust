#pragma once

#include "pbrt/base/bxdf.h"
#include "pbrt/spectrum_util/sampled_spectrum.h"
#include "pbrt/util/sampling.h"
#include <cuda/std/optional>

class DiffuseBxDF {
  public:
    PBRT_GPU DiffuseBxDF() : r(SampledSpectrum(NAN)) {}

    PBRT_GPU DiffuseBxDF(const SampledSpectrum &_r) {
        for (uint idx = 0; idx < NSpectrumSamples; ++idx) {
            r[idx] = _r[idx];
        }
    }

    PBRT_GPU
    void init(const SampledSpectrum &_r) {
        for (uint idx = 0; idx < NSpectrumSamples; ++idx) {
            r[idx] = _r[idx];
        }
    }

    PBRT_CPU_GPU
    BxDFFlags flags() const {
        if (r.is_positive()) {
            return BxDFFlags::DiffuseReflection;
        }

        return BxDFFlags::Unset;
    }

    PBRT_CPU_GPU
    void regularize() {}

    PBRT_GPU SampledSpectrum f(const Vector3f wo, const Vector3f wi,
                               const TransportMode mode) const {
        if (!wo.same_hemisphere(wi)) {
            return SampledSpectrum(0.0);
        }

        return r * (1.0 / compute_pi());
    }

    PBRT_GPU
    cuda::std::optional<BSDFSample>
    sample_f(Vector3f wo, FloatType uc, Point2f u, TransportMode mode = TransportMode::Radiance,
             BxDFReflTransFlags sample_flags = BxDFReflTransFlags::All) const {
        if (!(sample_flags & BxDFReflTransFlags::Reflection)) {
            return {};
        }

        // Sample cosine-weighted hemisphere to compute _wi_ and _pdf_
        Vector3f wi = sample_cosine_hemisphere(u);
        if (wo.z < 0) {
            wi.z *= -1;
        }

        FloatType pdf = cosine_hemisphere_pdf(wi.abs_cos_theta());

        return BSDFSample(r * (1.0 / compute_pi()), wi, pdf, BxDFFlags::DiffuseReflection);
    }

    PBRT_GPU
    FloatType pdf(Vector3f wo, Vector3f wi, TransportMode mode,
                  BxDFReflTransFlags sampleFlags = BxDFReflTransFlags::All) const {
        if (!(sampleFlags & BxDFReflTransFlags::Reflection) || !wo.same_hemisphere(wi)) {
            return 0;
        }

        return cosine_hemisphere_pdf(wi.abs_cos_theta());
    }

  private:
    SampledSpectrum r;
};
