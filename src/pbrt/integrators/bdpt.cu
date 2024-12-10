#include "pbrt/accelerator/hlbvh.h"
#include "pbrt/base/bxdf.h"
#include "pbrt/base/film.h"
#include "pbrt/base/integrator_base.h"
#include "pbrt/base/interaction.h"
#include "pbrt/base/material.h"
#include "pbrt/base/sampler.h"
#include "pbrt/gui/gl_object.h"
#include "pbrt/integrators/bdpt.h"
#include "pbrt/light_samplers/power_light_sampler.h"
#include "pbrt/lights/image_infinite_light.h"
#include "pbrt/samplers/stratified.h"
#include "pbrt/scene/parameter_dictionary.h"

const size_t NUM_SAMPLERS = 2 * 1024 * 1024;
// TODO: investigate the optimal NUM_SAMPLERS?

struct BDPTSample {
    Point2i p_pixel;
    FloatType weight;
    SampledSpectrum radiance;
    SampledWavelengths lambda;
};

static __global__ void gpu_init_stratified_samplers(Sampler *samplers,
                                                    StratifiedSampler *stratified_samplers,
                                                    uint samples_per_dimension, uint num) {
    const uint worker_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (worker_idx >= num) {
        return;
    }

    stratified_samplers[worker_idx].init(samples_per_dimension);

    samplers[worker_idx].init(&stratified_samplers[worker_idx]);
}

enum class VertexType { Camera, Light, Surface };

// ScopedAssignment Definition
template <typename Type>
class ScopedAssignment {
  public:
    PBRT_CPU_GPU
    explicit ScopedAssignment(Type *target = nullptr, Type value = Type()) : target(target) {
        if (target) {
            backup = *target;
            *target = value;
        }
    }

    PBRT_CPU_GPU
    void assign() {
        if (target)
            *target = backup;
    }

    ScopedAssignment(const ScopedAssignment &) = delete;

    ScopedAssignment &operator=(const ScopedAssignment &) = delete;

    PBRT_CPU_GPU
    ScopedAssignment &operator=(ScopedAssignment &&other) {
        target = other.target;
        backup = other.backup;
        other.target = nullptr;
        return *this;
    }

  private:
    Type *target, backup;
};

struct EndpointInteraction : Interaction {
    const Camera *camera;
    const Light *light;

    PBRT_CPU_GPU
    EndpointInteraction() : Interaction(), camera(nullptr), light(nullptr) {}

    PBRT_CPU_GPU
    EndpointInteraction(const Light *light, const Ray &r)
        : Interaction(r.o), camera(nullptr), light(light) {}

    PBRT_CPU_GPU
    EndpointInteraction(const Camera *camera, const Ray &ray)
        : Interaction(ray.o), camera(camera), light(nullptr) {}

    PBRT_CPU_GPU
    EndpointInteraction(const Light *light, const Interaction &intr)
        : Interaction(intr), camera(nullptr), light(light) {}

    PBRT_CPU_GPU
    EndpointInteraction(const Interaction &it, const Camera *camera)
        : Interaction(it), camera(camera), light(nullptr) {}

    PBRT_CPU_GPU
    EndpointInteraction(const Ray &ray)
        : Interaction(ray.at(1), Normal3f(-ray.d)), camera(nullptr), light(nullptr) {}
};

PBRT_GPU
FloatType InfiniteLightDensity(const Light **infinite_lights, int num_infinite_lights,
                               const PowerLightSampler *lightSampler, const Vector3f w) {
    FloatType pdf = 0;
    for (auto idx = 0; idx < num_infinite_lights; ++idx) {
        auto light = infinite_lights[idx];
        pdf += light->pdf_li(LightSampleContext(Interaction()), -w) * lightSampler->pmf(light);
    }

    return pdf;
}

struct Vertex {
    VertexType type;
    SampledSpectrum beta;
    EndpointInteraction ei;
    SurfaceInteraction si;
    BSDF bsdf;
    FullBxDF full_bxdf;
    // TODO: probably has to embed Bxdf into BSDF

    bool delta;
    FloatType pdfFwd;
    FloatType pdfRev;

    PBRT_CPU_GPU
    Vertex() : type(VertexType::Camera), beta(NAN), delta(false), pdfFwd(0), pdfRev(0) {}

    PBRT_CPU_GPU
    Vertex(VertexType _type, const EndpointInteraction &_ei, const SampledSpectrum &_beta)
        : type(_type), beta(_beta), delta(false), pdfFwd(0), pdfRev(0), ei(_ei) {}

    PBRT_CPU_GPU
    Vertex(const SurfaceInteraction &_si, const BSDF &_bsdf, const FullBxDF &_full_bxdf,
           const SampledSpectrum &_beta)
        : type(VertexType::Surface), beta(_beta), delta(false), pdfFwd(0), pdfRev(0), si(_si),
          bsdf(_bsdf), full_bxdf(_full_bxdf) {}

    PBRT_CPU_GPU
    bool IsLight() const {
        return type == VertexType::Light ||
               (type == VertexType::Surface && si.area_light != nullptr);
    }

    PBRT_CPU_GPU
    bool IsDeltaLight() const {
        return type == VertexType::Light && ei.light && is_delta_light(ei.light->get_light_type());
    }

    PBRT_CPU_GPU
    static Vertex CreateCamera(const Camera *camera, const Ray &ray, const SampledSpectrum &beta) {
        return Vertex(VertexType::Camera, EndpointInteraction(camera, ray), beta);
    }

    PBRT_CPU_GPU
    static Vertex CreateCamera(const Camera *camera, const Interaction &it,
                               const SampledSpectrum &beta) {
        return Vertex(VertexType::Camera, EndpointInteraction(it, camera), beta);
    }

    PBRT_CPU_GPU
    static Vertex CreateLight(const EndpointInteraction &ei, const SampledSpectrum &beta,
                              FloatType pdf) {
        Vertex v(VertexType::Light, ei, beta);
        v.pdfFwd = pdf;
        return v;
    }

    PBRT_CPU_GPU
    static Vertex CreateLight(const Light *light, const Interaction &intr,
                              const SampledSpectrum &Le, FloatType pdf) {
        Vertex v(VertexType::Light, EndpointInteraction(light, intr), Le);
        v.pdfFwd = pdf;
        return v;
    }

    PBRT_CPU_GPU
    static Vertex CreateLight(const Light *light, const Ray &ray, const SampledSpectrum &Le,
                              FloatType pdf) {
        Vertex v(VertexType::Light, EndpointInteraction(light, ray), Le);
        v.pdfFwd = pdf;
        return v;
    }

    PBRT_CPU_GPU
    static Vertex CreateSurface(const SurfaceInteraction &si, const BSDF &bsdf,
                                const FullBxDF &full_bxdf, const SampledSpectrum &beta,
                                FloatType pdf, const Vertex &prev) {
        Vertex v(si, bsdf, full_bxdf, beta);
        v.pdfFwd = prev.ConvertDensity(pdf, v);
        return v;
    }

    PBRT_CPU_GPU
    bool IsConnectible() const {
        switch (type) {
        case VertexType::Light: {
            return ei.light->get_light_type() != LightType::delta_direction;
        }
        case VertexType::Camera: {
            return true;
        }
        case VertexType::Surface: {
            return _is_non_specular(bsdf.flags());
        }
        }

        REPORT_FATAL_ERROR();
        return false;
    }

    PBRT_CPU_GPU
    const Interaction &get_interaction() const {
        switch (type) {
        case VertexType::Surface: {
            return si;
        }
        default: {
            return ei;
        }
        }

        REPORT_FATAL_ERROR();
    }

    PBRT_CPU_GPU
    const SurfaceInteraction &get_surface_interaction() const {
        if (type == VertexType::Surface) {
            return si;
        }

        REPORT_FATAL_ERROR();
        SurfaceInteraction unused;
        return unused;
    }

    PBRT_CPU_GPU
    Point3f p() const {
        return get_interaction().p();
    }

    PBRT_CPU_GPU
    const Normal3f &ng() const {
        return get_interaction().n;
    }

    PBRT_CPU_GPU
    const Normal3f &ns() const {
        if (type == VertexType::Surface) {
            return si.shading.n;
        }

        return get_interaction().n;
    }

    PBRT_CPU_GPU
    bool is_on_surface() const {
        return get_interaction().is_surface_interaction();
    }

    PBRT_GPU
    SampledSpectrum f(const Vertex &next, TransportMode mode) const {
        Vector3f wi = next.p() - p();

        if (wi.squared_length() == 0) {
            return {};
        }

        wi = wi.normalize();
        switch (type) {
        case VertexType::Surface:
            return bsdf.f(si.wo, wi, mode);
        }

        REPORT_FATAL_ERROR();
        return SampledSpectrum(NAN);
    }

    PBRT_CPU_GPU
    bool IsInfiniteLight() const {
        return type == VertexType::Light &&
               (!ei.light || ei.light->get_light_type() == LightType::infinite ||
                ei.light->get_light_type() == LightType::delta_direction);
    }

    PBRT_CPU_GPU
    FloatType ConvertDensity(FloatType pdf, const Vertex &next) const {
        // Return solid angle density if _next_ is an infinite area light
        if (next.IsInfiniteLight()) {
            return pdf;
        }

        Vector3f w = next.p() - p();
        if (w.squared_length() == 0) {
            return 0;
        }

        FloatType invDist2 = 1 / w.squared_length();
        if (next.is_on_surface()) {
            pdf *= next.ng().abs_dot(w * std::sqrt(invDist2));
        }

        return pdf * invDist2;
    }

    PBRT_GPU
    FloatType PDFLight(const IntegratorBase *integrator_base, const Vertex &v) const {
        Vector3f w = v.p() - p();
        auto invDist2 = 1.0 / w.squared_length();
        w *= std::sqrt(invDist2);

        // Compute sampling density _pdf_ for light type
        FloatType pdf;
        if (IsInfiniteLight()) {
            // Compute planar sampling density for infinite light sources
            Bounds3f sceneBounds = integrator_base->bvh->bounds();
            Point3f sceneCenter;
            FloatType sceneRadius;
            sceneBounds.bounding_sphere(&sceneCenter, &sceneRadius);
            pdf = 1.0 / (compute_pi() * sqr(sceneRadius));
        } else if (is_on_surface()) {
            // Compute sampling density at emissive surface
            if constexpr (DEBUG_MODE && type == VertexType::Light) {
                if (ei.light->get_light_type() != LightType::area) {
                    REPORT_FATAL_ERROR();
                }
            }

            auto light = (type == VertexType::Light) ? ei.light : si.area_light;
            FloatType pdfPos, pdfDir;
            light->pdf_le(ei, w, &pdfPos, &pdfDir);
            pdf = pdfDir * invDist2;
        } else {
            if constexpr (DEBUG_MODE) {
                if (type != VertexType::Light || ei.light == nullptr) {
                    REPORT_FATAL_ERROR();
                }
            }

            // Compute sampling density for noninfinite light sources
            FloatType pdfPos, pdfDir;
            ei.light->pdf_le(Ray(p(), w), &pdfPos, &pdfDir);
            pdf = pdfDir * invDist2;
        }

        if (v.is_on_surface()) {
            pdf *= v.ng().abs_dot(w);
        }

        return pdf;
    }

    PBRT_GPU
    FloatType PDF(const IntegratorBase *integrator_base, const Vertex *prev,
                  const Vertex &next) const {
        if (type == VertexType::Light) {
            return PDFLight(integrator_base, next);
        }

        // Compute directions to preceding and next vertex
        Vector3f wn = next.p() - p();
        if (wn.squared_length() == 0) {
            return 0;
        }

        wn = wn.normalize();
        Vector3f wp;
        if (prev) {
            wp = prev->p() - p();
            if (wp.squared_length() == 0) {
                return 0;
            }
            wp = wp.normalize();
        } else {
            if constexpr (DEBUG_MODE && type != VertexType::Camera) {
                REPORT_FATAL_ERROR();
            }
        }

        // Compute directional density depending on the vertex type
        FloatType pdf = 0;

        switch (type) {
        case VertexType::Camera: {
            FloatType unused;
            ei.camera->pdf_we(ei.spawn_ray(wn), &unused, &pdf);
            break;
        }
        case VertexType::Surface: {
            pdf = bsdf.pdf(wp, wn);
            break;
        }
        default: {
            REPORT_FATAL_ERROR();
        }
        }

        // Return probability per unit area at vertex _next_
        return ConvertDensity(pdf, next);
    }

    PBRT_GPU
    SampledSpectrum Le(const Light **infinite_lights, int num_infinite_lights, const Vertex &v,
                       const SampledWavelengths &lambda) const {
        if (!IsLight()) {
            return SampledSpectrum(0.0);
        }

        Vector3f w = v.p() - p();
        if (w.squared_length() == 0) {
            return SampledSpectrum(0.0);
        }

        w = w.normalize();
        if (IsInfiniteLight()) {
            // Return emitted radiance for infinite light sources
            SampledSpectrum Le(0.f);

            for (uint idx = 0; idx < num_infinite_lights; ++idx) {
                auto light = infinite_lights[idx];
                Le += light->le(Ray(p(), -w), lambda);
            }

            return Le;
        }

        if (si.area_light != nullptr) {
            return si.area_light->l(si.p(), si.n, si.uv, w, lambda);
        }

        return SampledSpectrum(0.f);
    }

    PBRT_GPU
    FloatType PDFLightOrigin(const Light **infinite_lights, int num_infinite_lights,
                             const Vertex &v, const PowerLightSampler *lightSampler) {
        Vector3f w = v.p() - p();
        if (w.squared_length() == 0) {
            return 0.0;
        }

        w = w.normalize();

        if (IsInfiniteLight()) {
            // Return sampling density for infinite light sources
            return InfiniteLightDensity(infinite_lights, num_infinite_lights, lightSampler, w);
        }

        // Return sampling density for noninfinite light source
        auto light = type == VertexType::Light ? ei.light : si.area_light;

        FloatType pdfPos, pdfDir;
        auto pdfChoice = lightSampler->pmf(light);

        if (is_on_surface()) {
            light->pdf_le(ei, w, &pdfPos, &pdfDir);
        } else {
            light->pdf_le(Ray(p(), w), &pdfPos, &pdfDir);
        }

        return pdfPos * pdfChoice;
    }
};

PBRT_GPU
SampledSpectrum G(const IntegratorBase *integrator_base, const Vertex &v0, const Vertex &v1,
                  const SampledWavelengths &lambda) {
    Vector3f d = v0.p() - v1.p();
    auto g = 1.0 / d.squared_length();
    d *= std::sqrt(g);
    if (v0.is_on_surface()) {
        g *= v0.ns().abs_dot(d);
    }

    if (v1.is_on_surface()) {
        g *= v1.ns().abs_dot(d);
    }

    return g * integrator_base->tr(v0.get_interaction(), v1.get_interaction());
}

PBRT_GPU
FloatType MISWeight(const IntegratorBase *integrator_base, Vertex *lightVertices,
                    Vertex *cameraVertices, Vertex &sampled, int s, int t) {
    if (s + t == 2) {
        return 1;
    }

    // Define helper function _remap0_ that deals with Dirac delta functions
    auto remap0 = [](float f) -> FloatType { return f != 0 ? f : 1.0; };

    // Temporarily update vertex properties for current strategy
    // Look up connection vertices and their predecessors
    Vertex *qs = s > 0 ? &lightVertices[s - 1] : nullptr,
           *pt = t > 0 ? &cameraVertices[t - 1] : nullptr,
           *qsMinus = s > 1 ? &lightVertices[s - 2] : nullptr,
           *ptMinus = t > 1 ? &cameraVertices[t - 2] : nullptr;

    // Update sampled vertex for $s=1$ or $t=1$ strategy
    ScopedAssignment<Vertex> a1;
    if (s == 1) {
        a1 = ScopedAssignment(qs, sampled);
    } else if (t == 1) {
        a1 = ScopedAssignment(pt, sampled);
    }

    // Mark connection vertices as non-degenerate
    ScopedAssignment<bool> a2, a3;
    if (pt) {
        a2 = ScopedAssignment(&pt->delta, false);
    }
    if (qs) {
        a3 = ScopedAssignment(&qs->delta, false);
    }

    // Update reverse density of vertex $\pt{}_{t-1}$
    ScopedAssignment<FloatType> a4;
    if (pt) {
        a4 = ScopedAssignment(&pt->pdfRev,
                              s > 0 ? qs->PDF(integrator_base, qsMinus, *pt)
                                    : pt->PDFLightOrigin(integrator_base->infinite_lights,
                                                         integrator_base->infinite_light_num,
                                                         *ptMinus, integrator_base->light_sampler));
    }

    // Update reverse density of vertex $\pt{}_{t-2}$
    ScopedAssignment<FloatType> a5;
    if (ptMinus) {
        a5 = ScopedAssignment(&ptMinus->pdfRev, s > 0 ? pt->PDF(integrator_base, qs, *ptMinus)
                                                      : pt->PDFLight(integrator_base, *ptMinus));
    }

    // Update reverse density of vertices $\pq{}_{s-1}$ and $\pq{}_{s-2}$
    ScopedAssignment<FloatType> a6;
    if (qs) {
        a6 = ScopedAssignment(&qs->pdfRev, pt->PDF(integrator_base, ptMinus, *qs));
    }

    ScopedAssignment<FloatType> a7;
    if (qsMinus) {
        a7 = ScopedAssignment(&qsMinus->pdfRev, qs->PDF(integrator_base, pt, *qsMinus));
    }

    FloatType sumRi = 0;

    // Consider hypothetical connection strategies along the camera subpath
    FloatType ri = 1.0;
    for (int i = t - 1; i > 0; --i) {
        ri *= remap0(cameraVertices[i].pdfRev) / remap0(cameraVertices[i].pdfFwd);
        if (!cameraVertices[i].delta && !cameraVertices[i - 1].delta) {
            sumRi += ri;
        }
    }

    ri = 1;
    for (int i = s - 1; i >= 0; --i) {
        ri *= remap0(lightVertices[i].pdfRev) / remap0(lightVertices[i].pdfFwd);
        bool deltaLightvertex =
            i > 0 ? lightVertices[i - 1].delta : lightVertices[0].IsDeltaLight();
        if (!lightVertices[i].delta && !deltaLightvertex) {
            sumRi += ri;
        }
    }

    a1.assign();
    a2.assign();
    a3.assign();
    a4.assign();
    a5.assign();
    a6.assign();
    a7.assign();

    return 1.0 / (1.0 + sumRi);
}

PBRT_GPU
int RandomWalk(const IntegratorBase *integrator_base, SampledWavelengths &lambda, Ray ray,
               Sampler *sampler, SampledSpectrum beta, FloatType pdf, int maxDepth,
               TransportMode mode, Vertex *path, bool regularize) {
    if (maxDepth == 0) {
        return 0;
    }

    const auto camera = integrator_base->camera;

    // Follow random walk to initialize BDPT path vertices
    int bounces = 0;
    bool anyNonSpecularBounces = false;
    auto pdfFwd = pdf;
    while (true) {
        if (!beta.is_positive()) {
            break;
        }

        bool scattered = false;
        bool terminated = false;

        // Trace a ray and sample the medium, if any
        Vertex &vertex = path[bounces];
        Vertex &prev = path[bounces - 1];
        auto si = integrator_base->intersect(ray, Infinity);

        // TODO: if (ray.medium) {}

        if (terminated) {
            return bounces;
        }
        if (scattered) {
            continue;
        }

        // Handle escaped rays after no medium scattering event
        if (!si) {
            // Capture escaped rays when tracing from the camera
            if (mode == TransportMode::Radiance) {
                vertex = Vertex::CreateLight(EndpointInteraction(ray), beta, pdfFwd);
                ++bounces;
            }
            break;
        }

        // Handle surface interaction for path generation
        SurfaceInteraction &isect = si->interaction;
        // Get BSDF and skip over medium boundaries
        isect.init_bsdf(vertex.bsdf, vertex.full_bxdf, ray, lambda, camera,
                        sampler->get_samples_per_pixel());

        // Possibly regularize the BSDF
        if (regularize && anyNonSpecularBounces) {
            vertex.bsdf.regularize();
        }

        // Initialize _vertex_ with surface intersection information
        vertex = Vertex::CreateSurface(isect, vertex.bsdf, vertex.full_bxdf, beta, pdfFwd, prev);
        // TODO: rewrite Vertex::CreateSurface() to get rid of FullBxDF

        if (++bounces >= maxDepth) {
            break;
        }

        // Sample BSDF at current vertex
        Vector3f wo = isect.wo;
        auto u = sampler->get_1d();

        auto bs = vertex.bsdf.sample_f(wo, u, sampler->get_2d(), mode);
        if (!bs) {
            break;
        }

        pdfFwd = bs->pdf_is_proportional ? vertex.bsdf.pdf(wo, bs->wi, mode) : bs->pdf;
        anyNonSpecularBounces |= !bs->is_specular();

        beta *= bs->f * isect.shading.n.abs_dot(bs->wi) / bs->pdf;
        ray = isect.spawn_ray(bs->wi);
        // spawn_ray() is simplified from the original one from PBRT-v4

        auto _pdfRev = vertex.bsdf.pdf(bs->wi, wo, !mode);

        if (bs->is_specular()) {
            vertex.delta = true;
            _pdfRev = pdfFwd = 0;
        }

        prev.pdfRev = vertex.ConvertDensity(_pdfRev, prev);
    }

    return bounces;
}

PBRT_GPU
int GenerateCameraSubpath(const IntegratorBase *integrator_base, const Ray &ray,
                          SampledWavelengths &lambda, Sampler *sampler, int maxDepth, Vertex *path,
                          bool regularize) {
    if (maxDepth == 0) {
        return 0;
    }

    const auto camera = integrator_base->camera;

    SampledSpectrum beta(1.f);
    // Generate first vertex on camera subpath and start random walk
    FloatType pdfPos, pdfDir;

    path[0] = Vertex::CreateCamera(camera, ray, beta);

    camera->pdf_we(ray, &pdfPos, &pdfDir);

    return RandomWalk(integrator_base, lambda, ray, sampler, beta, pdfDir, maxDepth - 1,
                      TransportMode::Radiance, path + 1, regularize) +
           1;
}

PBRT_GPU
int GenerateLightSubpath(const IntegratorBase *integrator_base, SampledWavelengths &lambda,
                         Sampler *sampler, int maxDepth, Vertex *path, bool regularize) {
    // Generate light subpath and initialize _path_ vertices
    if (maxDepth == 0) {
        return 0;
    }

    // Sample initial ray for light subpath
    // Sample light for BDPT light subpath
    auto sampledLight = integrator_base->light_sampler->sample(sampler->get_1d());
    if (!sampledLight) {
        return 0;
    }

    auto light = sampledLight->light;
    auto lightSamplePDF = sampledLight->p;

    auto ul0 = sampler->get_2d();
    auto ul1 = sampler->get_2d();
    auto les = light->sample_le(ul0, ul1, lambda);

    if (!les || les->pdfPos == 0 || les->pdfDir == 0 || !les->L.is_positive()) {
        return 0;
    }

    auto ray = les->ray;

    // Generate first vertex of light subpath
    auto p_l = lightSamplePDF * les->pdfPos;
    path[0] = les->intr ? Vertex::CreateLight(light, *les->intr, les->L, p_l)
                        : Vertex::CreateLight(light, ray, les->L, p_l);

    // Follow light subpath random walk
    SampledSpectrum beta = les->L * les->abs_cos_theta(ray.d) / (p_l * les->pdfDir);

    int nVertices = RandomWalk(integrator_base, lambda, ray, sampler, beta, les->pdfDir,
                               maxDepth - 1, TransportMode::Importance, path + 1, regularize);

    // Correct subpath sampling densities for infinite area lights
    if (path[0].IsInfiniteLight()) {
        // Set spatial density of _path[1]_ for infinite area light
        if (nVertices > 0) {
            path[1].pdfFwd = les->pdfPos;
            if (path[1].is_on_surface()) {
                path[1].pdfFwd *= path[1].ng().abs_dot(ray.d);
            }
        }

        // Set spatial density of _path[0]_ for infinite area light
        path[0].pdfFwd = InfiniteLightDensity(integrator_base->infinite_lights,
                                              integrator_base->infinite_light_num,
                                              integrator_base->light_sampler, ray.d);
    }

    return nVertices + 1;
}

PBRT_GPU
SampledSpectrum ConnectBDPT(const IntegratorBase *integrator_base, SampledWavelengths &lambda,
                            Vertex *lightVertices, Vertex *cameraVertices, int s, int t,
                            Sampler *sampler, cuda::std::optional<Point2f> *pRaster,
                            FloatType *misWeightPtr = nullptr) {
    SampledSpectrum L(0.f);
    // Ignore invalid connections related to infinite area lights
    if (t > 1 && s != 0 && cameraVertices[t - 1].type == VertexType::Light) {
        return SampledSpectrum(0.f);
    }

    auto camera = integrator_base->camera;

    // Perform connection and write contribution to _L_
    Vertex sampled;
    if (s == 0) {
        // Interpret the camera subpath as a complete path
        const Vertex &pt = cameraVertices[t - 1];
        if (pt.IsLight()) {
            L = pt.Le(integrator_base->infinite_lights, integrator_base->infinite_light_num,
                      cameraVertices[t - 2], lambda) *
                pt.beta;
        }

    } else if (t == 1) {
        // Sample a point on the camera and connect it to the light subpath
        const Vertex &qs = lightVertices[s - 1];
        if (qs.IsConnectible()) {
            if (auto cs = camera->sample_wi(qs.get_interaction(), sampler->get_2d(), lambda)) {
                *pRaster = cs->pRaster;
                // Initialize dynamically sampled vertex and _L_ for $t=1$ case
                sampled = Vertex::CreateCamera(camera, cs->pLens, cs->Wi / cs->pdf);

                L = qs.beta * qs.f(sampled, TransportMode::Importance) * sampled.beta;
                if (qs.is_on_surface()) {
                    L *= qs.ns().abs_dot(cs->wi);
                }

                if (L.is_positive()) {
                    L *= integrator_base->tr(cs->pRef, cs->pLens);
                }
            }
        }
    } else if (s == 1) {
        // Sample a point on a light and connect it to the camera subpath
        const Vertex &pt = cameraVertices[t - 1];
        if (pt.IsConnectible()) {
            auto sampledLight = integrator_base->light_sampler->sample(sampler->get_1d());
            if (sampledLight) {
                auto light = sampledLight->light;
                auto p_l = sampledLight->p;

                LightSampleContext ctx;
                if (pt.is_on_surface()) {
                    const SurfaceInteraction &si = pt.get_surface_interaction();
                    ctx = LightSampleContext(si);
                    // Try to nudge the light sampling position to correct side of the
                    // surface
                    BxDFFlags flags = pt.bsdf.flags();
                    if (_is_reflective(flags) && !_is_transmissive(flags)) {
                        ctx.pi = si.offset_ray_origin(si.wo);
                    } else if (_is_transmissive(flags) && !_is_reflective(flags)) {
                        ctx.pi = si.offset_ray_origin(-si.wo);
                    }
                } else {
                    ctx = LightSampleContext(pt.get_interaction());
                }

                auto lightWeight = light->sample_li(ctx, sampler->get_2d(), lambda);
                if (lightWeight && lightWeight->l.is_positive() && lightWeight->pdf > 0) {
                    EndpointInteraction ei(light, lightWeight->p_light);

                    sampled = Vertex::CreateLight(ei, lightWeight->l / (lightWeight->pdf * p_l), 0);
                    sampled.pdfFwd = sampled.PDFLightOrigin(integrator_base->infinite_lights,
                                                            integrator_base->infinite_light_num, pt,
                                                            integrator_base->light_sampler);

                    L = pt.beta * pt.f(sampled, TransportMode::Radiance) * sampled.beta;

                    if (pt.is_on_surface()) {
                        L *= pt.ns().abs_dot(lightWeight->wi);
                    }

                    // Only check visibility if the path would carry radiance.
                    if (L.is_positive()) {
                        L *= integrator_base->tr(pt.get_interaction(), lightWeight->p_light);
                    }
                }
            }
        }
    } else {
        // Handle all other bidirectional connection cases
        const Vertex &qs = lightVertices[s - 1], &pt = cameraVertices[t - 1];
        if (qs.IsConnectible() && pt.IsConnectible()) {
            L = qs.beta * qs.f(pt, TransportMode::Importance) * pt.f(qs, TransportMode::Radiance) *
                pt.beta;

            if (L.is_positive()) {
                L *= G(integrator_base, qs, pt, lambda);
            }
        }
    }

    // Compute MIS weight for connection strategy
    FloatType misWeight =
        L.is_positive() ? MISWeight(integrator_base, lightVertices, cameraVertices, sampled, s, t)
                        : 0.0;

    L *= misWeight;
    if (misWeightPtr) {
        *misWeightPtr = misWeight;
    }

    return L;
}

BDPTIntegrator *BDPTIntegrator::create(const ParameterDictionary &parameters,
                                       const IntegratorBase *integrator_base,
                                       const std::string &sampler_type, const int samples_per_pixel,
                                       std::vector<void *> &gpu_dynamic_pointers) {
    BDPTIntegrator *bdpt_integrator;
    CHECK_CUDA_ERROR(cudaMallocManaged(&bdpt_integrator, sizeof(BDPTIntegrator)));
    gpu_dynamic_pointers.push_back(bdpt_integrator);

    Sampler *samplers;
    CHECK_CUDA_ERROR(cudaMallocManaged(&samplers, sizeof(Sampler) * NUM_SAMPLERS));
    gpu_dynamic_pointers.push_back(samplers);

    bdpt_integrator->samplers = samplers;
    bdpt_integrator->base = integrator_base;
    bdpt_integrator->max_depth = parameters.get_integer("maxdepth", 10);

    if (sampler_type == "stratified") {
        const uint samples_per_dimension = std::sqrt(samples_per_pixel);
        if (samples_per_dimension * samples_per_dimension != samples_per_pixel) {
            REPORT_FATAL_ERROR();
        }

        StratifiedSampler *stratified_samplers;
        CHECK_CUDA_ERROR(
            cudaMallocManaged(&stratified_samplers, sizeof(StratifiedSampler) * NUM_SAMPLERS));
        gpu_dynamic_pointers.push_back(stratified_samplers);

        const uint threads = 1024;
        uint blocks = divide_and_ceil<uint>(NUM_SAMPLERS, threads);
        gpu_init_stratified_samplers<<<blocks, threads>>>(samplers, stratified_samplers,
                                                          samples_per_dimension, NUM_SAMPLERS);
    } else {
        REPORT_FATAL_ERROR();
    }

    return bdpt_integrator;
}

__global__ void wavefront_render(BDPTSample *bdpt_samples, Vertex *global_camera_vertices,
                                 Vertex *global_light_vertices, uint pass, uint samples_per_pixel,
                                 const Point2i film_resolution, BDPTIntegrator *bdpt_integrator) {
    const uint worker_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (worker_idx >= NUM_SAMPLERS) {
        return;
    }

    const auto width = film_resolution.x;
    const auto height = film_resolution.y;

    auto global_idx = (long long)(pass)*NUM_SAMPLERS + worker_idx;

    auto pixel_idx = global_idx % (width * height);
    auto sample_idx = global_idx / (width * height);
    if (sample_idx >= samples_per_pixel) {
        return;
    }

    auto local_sampler = &bdpt_integrator->samplers[pixel_idx];
    local_sampler->start_pixel_sample(pixel_idx, sample_idx, 0);

    auto p_pixel = Point2i(pixel_idx % width, pixel_idx / width);

    auto camera_sample = local_sampler->get_camera_sample(p_pixel, bdpt_integrator->base->filter);

    auto lu = local_sampler->get_1d();
    auto lambda = SampledWavelengths::sample_visible(lu);

    auto ray = bdpt_integrator->base->camera->generate_ray(camera_sample, local_sampler);

    auto local_camera_vertices =
        &global_camera_vertices[worker_idx * (bdpt_integrator->max_depth + 2)];
    auto local_light_vertices =
        &global_light_vertices[worker_idx * (bdpt_integrator->max_depth + 1)];

    auto radiance_l = ray.weight * bdpt_integrator->li(ray.ray, lambda, local_sampler,
                                                       local_camera_vertices, local_light_vertices);

    bdpt_samples[pixel_idx] = {p_pixel, camera_sample.filter_weight, radiance_l, lambda};
}

void BDPTIntegrator::render(Film *film, uint samples_per_pixel, const std::string &output_filename,
                            bool preview) {
    const auto image_resolution = film->get_resolution();

    GLObject gl_object;
    if (preview) {
        gl_object.init(output_filename, image_resolution);
    }

    std::vector<uint8_t> cpu_frame_buffer(3 * image_resolution.x * image_resolution.y);

    std::vector<void *> gpu_dynamic_pointers;

    BDPTSample *bdpt_samples;
    CHECK_CUDA_ERROR(cudaMallocManaged(&bdpt_samples, sizeof(BDPTSample) * NUM_SAMPLERS));
    gpu_dynamic_pointers.push_back(bdpt_samples);

    Vertex *global_camera_vertices;
    Vertex *global_light_vertices;
    CHECK_CUDA_ERROR(cudaMallocManaged(&global_camera_vertices,
                                       sizeof(Vertex) * NUM_SAMPLERS * (max_depth + 2)));
    CHECK_CUDA_ERROR(
        cudaMallocManaged(&global_light_vertices, sizeof(Vertex) * NUM_SAMPLERS * (max_depth + 1)));
    gpu_dynamic_pointers.push_back(global_camera_vertices);
    gpu_dynamic_pointers.push_back(global_light_vertices);

    auto num_pixels = image_resolution.x * image_resolution.y;

    constexpr uint threads = 256;
    const uint blocks = divide_and_ceil<uint>(num_pixels, threads);

    auto total_pass = divide_and_ceil<long long>(num_pixels * samples_per_pixel, NUM_SAMPLERS);
    for (uint pass = 0; pass < total_pass; ++pass) {
        wavefront_render<<<blocks, threads>>>(bdpt_samples, global_camera_vertices,
                                              global_light_vertices, pass, samples_per_pixel,
                                              film->get_resolution(), this);
        CHECK_CUDA_ERROR(cudaDeviceSynchronize());

        for (uint idx = 0; idx < NUM_SAMPLERS; ++idx) {
            auto global_idx = (long long)(NUM_SAMPLERS)*pass + idx;
            if (global_idx / num_pixels >= samples_per_pixel) {
                break;
            }

            const auto sample = &bdpt_samples[idx];
            film->add_sample(sample->p_pixel, sample->radiance, sample->lambda, sample->weight);
        }

        if (preview) {
            film->copy_to_frame_buffer(cpu_frame_buffer);

            auto current_sample_idx = (long long)(NUM_SAMPLERS)*pass / num_pixels;
            auto title = output_filename + " - samples: " + std::to_string(current_sample_idx + 1) +
                         "/" + std::to_string(samples_per_pixel) +
                         " - pass: " + std::to_string(pass);

            gl_object.draw_frame(cpu_frame_buffer, title, image_resolution);
        }
    }

    for (auto ptr : gpu_dynamic_pointers) {
        CHECK_CUDA_ERROR(cudaFree(ptr));
    }
    CHECK_CUDA_ERROR(cudaGetLastError());
}

PBRT_GPU
SampledSpectrum BDPTIntegrator::li(const Ray &ray, SampledWavelengths &lambda, Sampler *sampler,
                                   Vertex *camera_vertices, Vertex *light_vertices) const {
    // Trace the camera and light subpaths
    const auto regularize = true;

    int nCamera = GenerateCameraSubpath(base, ray, lambda, sampler, max_depth + 2, camera_vertices,
                                        regularize);
    int nLight =
        GenerateLightSubpath(base, lambda, sampler, max_depth + 1, light_vertices, regularize);

    SampledSpectrum accumulated_l(0);
    // Execute all BDPT connection strategies
    for (int t = 1; t <= nCamera; ++t) {
        for (int s = 0; s <= nLight; ++s) {
            int depth = t + s - 2;
            if ((s == 1 && t == 1) || depth < 0 || depth > max_depth) {
                continue;
            }

            // Execute the $(s, t)$ connection strategy and update _L_
            cuda::std::optional<Point2f> pFilmNew;
            FloatType misWeight = 0;
            SampledSpectrum l_path = ConnectBDPT(base, lambda, light_vertices, camera_vertices, s,
                                                 t, sampler, &pFilmNew, &misWeight);

            if (t != 1) {
                accumulated_l += l_path;
            } else if (l_path.is_positive()) {
                if constexpr (DEBUG_MODE && !pFilmNew.has_value()) {
                    REPORT_FATAL_ERROR();
                }

                /*
                film->add_splat(*pFilmNew, Lpath, lambda, 1);
                // TODO: record splat spectrum
                */
            }
        }
    }

    return accumulated_l;
}