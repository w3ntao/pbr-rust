#pragma once

#include "pbrt/euclidean_space/vector3.h"

// Vector3fi Definition
class Vector3fi : public Vector3<Interval> {
  public:
    // Vector3fi Public Methods
    using Vector3<Interval>::x;
    using Vector3<Interval>::y;
    using Vector3<Interval>::z;
    using Vector3<Interval>::operator+;
    using Vector3<Interval>::operator+=;
    using Vector3<Interval>::operator*;
    using Vector3<Interval>::operator*=;

    Vector3fi() = default;

    PBRT_CPU_GPU
    Vector3fi(double x, double y, double z)
        : Vector3<Interval>(Interval(x), Interval(y), Interval(z)) {}

    PBRT_CPU_GPU
    Vector3fi(Interval x, Interval y, Interval z) : Vector3<Interval>(x, y, z) {}

    PBRT_CPU_GPU
    Vector3fi(Vector3f p) : Vector3<Interval>(Interval(p.x), Interval(p.y), Interval(p.z)) {}

    template <typename T>
    PBRT_CPU_GPU explicit Vector3fi(Point3<T> p)
        : Vector3<Interval>(Interval(p.x), Interval(p.y), Interval(p.z)) {}

    PBRT_CPU_GPU Vector3fi(Vector3<Interval> pfi) : Vector3<Interval>(pfi) {}

    PBRT_CPU_GPU
    Vector3fi(Vector3f v, Vector3f e)
        : Vector3<Interval>(Interval::from_value_and_error(v.x, e.x),
                            Interval::from_value_and_error(v.y, e.y),
                            Interval::from_value_and_error(v.z, e.z)) {}

    PBRT_CPU_GPU
    Vector3f Error() const {
        return {x.width() / 2, y.width() / 2, z.width() / 2};
    }
    PBRT_CPU_GPU
    bool IsExact() const {
        return x.width() == 0 && y.width() == 0 && z.width() == 0;
    }
};
