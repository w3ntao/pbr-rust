#include "pbrt/base/bsdf.h"

PBRT_GPU
void BSDF::init_frame(const Normal3f &ns, const Vector3f &dpdus) {
    shading_frame = Frame::from_xz(dpdus.normalize(), ns.to_vector3());
}

PBRT_GPU
void BSDF::init_bxdf(const ConductorBxDF &conductor_bxdf) {
    bxdf.init(conductor_bxdf);
}

PBRT_GPU
void BSDF::init_bxdf(const CoatedConductorBxDF &coated_conductor_bxdf) {
    bxdf.init(coated_conductor_bxdf);
}

PBRT_GPU
void BSDF::init_bxdf(const CoatedDiffuseBxDF &coated_diffuse_bxdf) {
    bxdf.init(coated_diffuse_bxdf);
}

PBRT_GPU
void BSDF::init_bxdf(const DielectricBxDF &dielectric_bxdf) {
    bxdf.init(dielectric_bxdf);
}

PBRT_GPU
void BSDF::init_bxdf(const DiffuseBxDF &diffuse_bxdf) {
    bxdf.init(diffuse_bxdf);
}

PBRT_GPU
SampledSpectrum BSDF::f(const Vector3f &woRender, const Vector3f &wiRender,
                        const TransportMode mode) const {
    Vector3f wi = render_to_local(wiRender);
    Vector3f wo = render_to_local(woRender);

    if (wo.z == 0) {
        return SampledSpectrum(0.0);
    }

    return bxdf.f(wo, wi, mode);
}

PBRT_GPU
cuda::std::optional<BSDFSample> BSDF::sample_f(const Vector3f &wo_render, FloatType u,
                                               const Point2f &u2, TransportMode mode,
                                               BxDFReflTransFlags sample_flags) const {
    if (bxdf.has_type_null()) {
        REPORT_FATAL_ERROR();
    }

    const auto wo = render_to_local(wo_render);

    if (wo.z == 0 || !(bxdf.flags() & sample_flags)) {
        return {};
    }

    auto bs = bxdf.sample_f(wo, u, u2, mode, sample_flags);
    if (!bs || !bs->f.is_positive() || bs->pdf == 0 || bs->wi.z == 0) {
        return {};
    }

    bs->wi = local_to_render(bs->wi);
    return bs;
}

PBRT_GPU
FloatType BSDF::pdf(const Vector3f &woRender, const Vector3f &wiRender, TransportMode mode,
                    BxDFReflTransFlags sampleFlags) const {
    Vector3f wo = render_to_local(woRender);
    Vector3f wi = render_to_local(wiRender);

    if (wo.z == 0) {
        return 0;
    }

    return bxdf.pdf(wo, wi, mode, sampleFlags);
}
