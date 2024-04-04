#include "pbrt/base/shape.h"
#include "pbrt/shapes/triangle.h"

PBRT_CPU_GPU
void Shape::init(const Triangle *triangle) {
    shape_type = ShapeType::triangle;
    shape_ptr = (void *)triangle;
}

PBRT_CPU_GPU
Bounds3f Shape::bounds() const {
    switch (shape_type) {
    case (ShapeType::triangle): {
        return ((Triangle *)shape_ptr)->bounds();
    }
    }

    report_error();
}

PBRT_GPU
bool Shape::fast_intersect(const Ray &ray, double t_max) const {
    switch (shape_type) {
    case (ShapeType::triangle): {
        return ((Triangle *)shape_ptr)->fast_intersect(ray, t_max);
    }
    }

    report_error();
}

PBRT_GPU
std::optional<ShapeIntersection> Shape::intersect(const Ray &ray, double t_max) const {
    switch (shape_type) {
    case (ShapeType::triangle): {
        return ((Triangle *)shape_ptr)->intersect(ray, t_max);
    }
    }

    report_error();
}