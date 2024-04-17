#pragma once

#include <iostream>
#include <string>

#include "pbrt/base/camera.h"
#include "pbrt/base/filter.h"
#include "pbrt/base/integrator.h"
#include "pbrt/base/shape.h"
#include "pbrt/base/spectrum.h"

#include "pbrt/accelerator/hlbvh.h"

#include "pbrt/cameras/perspective.h"

#include "pbrt/films/pixel_sensor.h"
#include "pbrt/films/rgb_film.h"

#include "pbrt/samplers/independent.h"

#include "pbrt/shapes/triangle.h"

#include "pbrt/spectra/constants.h"
#include "pbrt/spectra/color_encoding.h"
#include "pbrt/spectra/rgb_color_space.h"
#include "pbrt/spectra/sampled_wavelengths.h"
#include "pbrt/spectra/densely_sampled_spectrum.h"

namespace GPU {

struct GlobalVariable {
    void init(const Spectrum *_cie_xyz[3], const Spectrum *cie_illum_d6500,
              const RGBtoSpectrumData::RGBtoSpectrumTable *rgb_to_spectrum_table,
              RGBtoSpectrumData::Gamut gamut) {
        for (uint idx = 0; idx < 3; idx++) {
            cie_xyz[idx] = _cie_xyz[idx];
        }

        if (gamut == RGBtoSpectrumData::Gamut::sRGB) {
            rgb_color_space->init(Point2f(0.64, 0.33), Point2f(0.3, 0.6), Point2f(0.15, 0.06),
                                  cie_illum_d6500, rgb_to_spectrum_table, cie_xyz);

            return;
        }

        throw std::runtime_error(
            "\nGlobalVariable::init(): this color space is not implemented\n\n");
    }

    PBRT_CPU_GPU void get_cie_xyz(const Spectrum *out[3]) const {
        for (uint idx = 0; idx < 3; idx++) {
            out[idx] = cie_xyz[idx];
        }
    }

    RGBColorSpace *rgb_color_space;
    const Spectrum *cie_xyz[3];
};

class Renderer {
  public:
    Integrator *integrator;
    Camera *camera;
    Filter *filter;
    Film *film;
    HLBVH *bvh;

    const GlobalVariable *global_variables;

    PixelSensor sensor;

    PBRT_GPU void evaluate_pixel_sample(const Point2i p_pixel, const int num_samples) {
        int width = camera->get_camerabase()->resolution.x;
        int pixel_index = p_pixel.y * width + p_pixel.x;

        auto sampler = IndependentSampler(pixel_index);

        for (uint i = 0; i < num_samples; ++i) {
            auto camera_sample = sampler.get_camera_sample(p_pixel, filter);
            auto lu = sampler.get_1d();
            auto lambda = SampledWavelengths::sample_visible(lu);

            auto ray = camera->generate_ray(camera_sample);

            auto radiance_l = ray.weight * integrator->li(ray.ray, lambda, bvh, sampler);

            if (radiance_l.has_nan()) {
                printf("evaluate_pixel_sample(): pixel(%d, %d), samples %u: has an NAN component\n",
                       p_pixel.x, p_pixel.y, i);
            }

            film->add_sample(p_pixel, radiance_l, lambda, camera_sample.filter_weight);
        }
    }
};

template <typename S>
static __global__ void build_shapes(Shape *shapes, const S *concrete_shapes, uint num) {
    const uint worker_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (worker_idx >= num) {
        return;
    }

    shapes[worker_idx].init(&concrete_shapes[worker_idx]);
}

template <typename T>
static __global__ void apply_transform(T *data, const Transform transform, uint length) {
    uint idx = threadIdx.x + blockIdx.x * blockDim.x;
    if (idx >= length) {
        return;
    }

    data[idx] = transform(data[idx]);
}

static __global__ void init_pixels(Pixel *pixels, Point2i dimension) {
    uint idx = threadIdx.x + blockIdx.x * blockDim.x;
    if (idx >= dimension.x * dimension.y) {
        return;
    }

    pixels[idx].init_zero();
}

__global__ void init_triangles_from_mesh(Triangle *triangles, const TriangleMesh *mesh) {
    const uint worker_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (worker_idx >= mesh->triangle_num) {
        return;
    }

    triangles[worker_idx].init(worker_idx, mesh);
}

__global__ void parallel_render(Renderer *renderer, int num_samples) {
    auto camera_base = renderer->camera->get_camerabase();

    uint width = camera_base->resolution.x;
    uint height = camera_base->resolution.y;

    uint x = threadIdx.x + blockIdx.x * blockDim.x;
    uint y = threadIdx.y + blockIdx.y * blockDim.y;
    if (x >= width || y >= height) {
        return;
    }

    renderer->evaluate_pixel_sample(Point2i(x, y), num_samples);
}
} // namespace GPU
