#pragma once

#include "pbrt/base/camera.h"
#include "pbrt/euclidean_space/bounds2.h"

class PerspectiveCamera {
  public:
    void init(const Point2i resolution, const CameraTransform camera_transform, FloatType fov,
              FloatType _lens_radius) {
        camera_base.init(resolution, camera_transform);
        lens_radius = _lens_radius;

        auto frame_aspect_ratio = FloatType(resolution.x) / FloatType(resolution.y);

        auto screen_window =
            frame_aspect_ratio > 1.0
                ? Bounds2f(Point2f(-frame_aspect_ratio, -1.0), Point2f(frame_aspect_ratio, 1.0))
                : Bounds2f(Point2f(-1.0, -1.0 / frame_aspect_ratio),
                           Point2f(1.0, 1.0 / frame_aspect_ratio));

        auto ndc_from_screen =
            Transform::scale(1.0 / (screen_window.p_max.x - screen_window.p_min.x),
                             1.0 / (screen_window.p_max.y - screen_window.p_min.y), 1.0) *
            Transform::translate(-screen_window.p_min.x, -screen_window.p_max.y, 0.0);

        auto raster_from_ndc = Transform::scale(resolution.x, -resolution.y, 1.0);

        raster_from_screen = raster_from_ndc * ndc_from_screen;

        screen_from_raster = raster_from_screen.inverse();

        screen_from_camera = Transform::perspective(fov, 1e-2, 1000.0);

        camera_from_raster = screen_from_camera.inverse() * screen_from_raster;

        dx_camera =
            camera_from_raster(Point3f(1.0, 0.0, 0.0)) - camera_from_raster(Point3f(0.0, 0.0, 0.0));

        dy_camera =
            camera_from_raster(Point3f(0.0, 1.0, 0.0)) - camera_from_raster(Point3f(0.0, 0.0, 0.0));
    }

    PBRT_CPU_GPU CameraRay generate_ray(const CameraSample &sample) const {
        Point3f pFilm = Point3f(sample.p_film.x, sample.p_film.y, 0);
        Point3f pCamera = camera_from_raster(pFilm);

        Ray ray(Point3f(0, 0, 0), pCamera.to_vector3().normalize());

        if (lens_radius > 0) {
            printf("PerspectiveCamera::init(): lens_radius > 0 not implemented\n");

#if defined(__CUDA_ARCH__)
            asm("trap;");
#else
            throw std::runtime_error("PerspectiveCamera::init()\n");
#endif
        }

        return CameraRay(camera_base.camera_transform.render_from_camera(ray));
    }

    CameraBase camera_base;

  private:
    Transform raster_from_screen;
    Transform screen_from_raster;
    Transform screen_from_camera;
    Transform camera_from_raster;

    Vector3f dx_camera;
    Vector3f dy_camera;

    FloatType lens_radius;
};
