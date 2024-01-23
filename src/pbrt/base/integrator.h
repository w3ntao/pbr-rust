#pragma once

#include <curand_kernel.h>

#include "pbrt/base/color.h"
#include "pbrt/base/ray.h"
#include "pbrt/base/world.h"

class Integrator {
  public:
    PBRT_GPU virtual ~Integrator() {}

    PBRT_GPU virtual Color get_radiance(const Ray &ray, const World *world,
                                        curandState *local_rand_state) const = 0;
};