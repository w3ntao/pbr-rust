#pragma once

#include "pbrt/euclidean_space/point2.h"
#include "pbrt/base/camera.h"

class Filter;
class IndependentSampler;

class Sampler {
  public:
    enum class Type {
        independent_sampler,
    };

    PBRT_CPU_GPU
    void init(IndependentSampler *independent_sampler);

    PBRT_GPU
    void start_pixel_sample(uint pixel_idx, uint sample_idx, uint dimension);

    PBRT_CPU_GPU
    uint get_samples_per_pixel() const;

    PBRT_GPU FloatType get_1d();

    PBRT_GPU Point2f get_2d();

    PBRT_GPU Point2f get_pixel_2d();

    PBRT_GPU
    CameraSample get_camera_sample(Point2i pPixel, const Filter *filter);

  private:
    Type sampler_type;
    void *sampler_ptr;
};
