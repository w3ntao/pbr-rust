#include "pbrt/base/bxdf.h"
#include "pbrt/bxdfs/diffuse_bxdf.h"
#include "pbrt/bxdfs/dielectric_bxdf.h"

PBRT_GPU
void BxDF::init(const DiffuseBxDF *diffuse_bxdf) {
    bxdf_type = Type::diffuse_bxdf;
    bxdf_ptr = diffuse_bxdf;
}

PBRT_GPU
void BxDF::init(const DielectricBxDF *dielectric_bxdf) {
    bxdf_type = Type::dielectric_bxdf;
    bxdf_ptr = dielectric_bxdf;
}

PBRT_CPU_GPU
BxDFFlags BxDF::flags() const {
    switch (bxdf_type) {
    case (Type::diffuse_bxdf): {
        return ((DiffuseBxDF *)bxdf_ptr)->flags();
    }

    case (Type::dielectric_bxdf): {
        return ((DielectricBxDF *)bxdf_ptr)->flags();
    }
    }

    REPORT_FATAL_ERROR();
    return {};
}

PBRT_GPU
SampledSpectrum BxDF::f(Vector3f wo, Vector3f wi, TransportMode mode) const {
    switch (bxdf_type) {
    case (Type::diffuse_bxdf): {
        return ((DiffuseBxDF *)bxdf_ptr)->f(wo, wi, mode);
    }
    case (Type::dielectric_bxdf): {
        return ((DielectricBxDF *)bxdf_ptr)->f(wo, wi, mode);
    }
    }

    REPORT_FATAL_ERROR();
    return {};
}

PBRT_GPU
cuda::std::optional<BSDFSample> BxDF::sample_f(Vector3f wo, FloatType uc, Point2f u,
                                               TransportMode mode,
                                               BxDFReflTransFlags sampleFlags) const {
    switch (bxdf_type) {
    case (Type::diffuse_bxdf): {
        return ((DiffuseBxDF *)bxdf_ptr)->sample_f(wo, uc, u, mode, sampleFlags);
    }

    case (Type::dielectric_bxdf): {
        return ((DielectricBxDF *)bxdf_ptr)->sample_f(wo, uc, u, mode, sampleFlags);
    }
    }

    REPORT_FATAL_ERROR();
    return {};
}

PBRT_GPU
FloatType BxDF::pdf(Vector3f wo, Vector3f wi, TransportMode mode,
                    BxDFReflTransFlags sampleFlags) const {
    switch (bxdf_type) {
    case (Type::diffuse_bxdf): {
        return ((DiffuseBxDF *)bxdf_ptr)->pdf(wo, wi, mode, sampleFlags);
    }

    case (Type::dielectric_bxdf): {
        return ((DielectricBxDF *)bxdf_ptr)->pdf(wo, wi, mode, sampleFlags);
    }
    }

    REPORT_FATAL_ERROR();
    return {};
}
