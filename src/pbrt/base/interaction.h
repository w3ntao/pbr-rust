#pragma once

#include "pbrt/base/ray.h"
#include "pbrt/base/bsdf.h"

#include "pbrt/euclidean_space/point2.h"
#include "pbrt/euclidean_space/normal3f.h"
#include "pbrt/euclidean_space/point3fi.h"

#include "pbrt/spectrum_util/sampled_spectrum.h"

class DiffuseMaterial;
class DiffuseAreaLight;
class Camera;
class Sampler;
class SampledWavelengths;

class Interaction {
  public:
    Point3fi pi;
    Vector3f wo;
    Normal3f n;
    Point2f uv;

    PBRT_CPU_GPU
    explicit Interaction(const Point3fi &pi, const Normal3f &n, const Point2f &uv,
                         const Vector3f &wo)
        : pi(pi), n(n), uv(uv), wo(wo.normalize()) {}
};

class SurfaceInteraction : public Interaction {
  public:
    Vector3f dpdu, dpdv;
    Normal3f dndu, dndv;
    struct {
        Normal3f n;
        Vector3f dpdu, dpdv;
        Normal3f dndu, dndv;
    } shading;
    int faceIndex = 0;

    Vector3f dpdx;
    Vector3f dpdy;
    FloatType dudx = NAN;
    FloatType dvdx = NAN;
    FloatType dudy = NAN;
    FloatType dvdy = NAN;

    const DiffuseMaterial *material;
    // TODO: rewrite DiffuseMaterial to Material
    const DiffuseAreaLight *area_light;
    // TODO: rewrite DiffuseAreaLight to Light

    PBRT_CPU_GPU
    explicit SurfaceInteraction(const Point3fi &pi, const Point2f &uv, const Vector3f &wo,
                                const Vector3f &dpdu, const Vector3f &dpdv, Normal3f dndu,
                                const Normal3f &dndv, bool flip_normal)
        : Interaction(pi, Normal3f(dpdu.cross(dpdv).normalize()), uv, wo), dpdu(dpdu), dpdv(dpdv),
          dndu(dndu), dndv(dndv), material(nullptr), area_light(nullptr) {
        // Initialize shading geometry from true geometry
        shading.n = n;
        shading.dpdu = dpdu;
        shading.dpdv = dpdv;
        shading.dndu = dndu;
        shading.dndv = dndv;

        // Adjust normal based on orientation and handedness
        if (flip_normal) {
            n *= -1;
            shading.n *= -1;
        }
    }

    PBRT_CPU_GPU
    Point3f offset_ray_origin(const Vector3f &w) const {
        return Ray::offset_ray_origin(pi, n, w);
    }

    PBRT_GPU DifferentialRay spawn_ray(const Vector3f &d) const {
        return DifferentialRay(offset_ray_origin(d), d);
    }

    PBRT_GPU
    void compute_differentials(const Ray &ray, const Camera *camera, int samples_per_pixel);
    // TODO: rewrite compute_differentials(): change Ray to RayDifferential

    PBRT_GPU
    void set_intersection_properties(const DiffuseMaterial *_material,
                                     const DiffuseAreaLight *_area_light);

    PBRT_GPU
    void init_diffuse_bsdf(BSDF &bsdf, DiffuseBxDF &diffuse_bxdf, const Ray &ray,
                           SampledWavelengths &lambda, const Camera *camera, Sampler &sampler);

    PBRT_GPU SampledSpectrum le(Vector3f w, const SampledWavelengths &lambda) const;
};

// ShapeIntersection Definition
struct ShapeIntersection {
    SurfaceInteraction interaction;
    FloatType t_hit;

    PBRT_CPU_GPU ShapeIntersection(const SurfaceInteraction &si, FloatType t)
        : interaction(si), t_hit(t) {}
};
