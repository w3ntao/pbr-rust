#pragma once

#include "pbrt/euclidean_space/bounds2.h"
#include "pbrt/util/piecewise_constant_1d.h"

class PiecewiseConstant2D {
  public:
    void init(const Array2D<FloatType> *func, const Bounds2f &_domain,
              std::vector<void *> &gpu_dynamic_pointers) {
        const int nu = func->x_size();
        const int nv = func->y_size();

        domain = _domain;

        CHECK_CUDA_ERROR(cudaMallocManaged(&pConditionalV, sizeof(PiecewiseConstant1D) * nv));
        gpu_dynamic_pointers.push_back(pConditionalV);

        for (uint v = 0; v < nv; ++v) {
            // Compute conditional sampling distribution for $\tilde{v}$
            pConditionalV[v].init(func->get_values_ptr() + v * nu, nu, domain.p_min[0],
                                  domain.p_max[0], gpu_dynamic_pointers);
        }

        std::vector<FloatType> marginalFunc;
        for (int v = 0; v < nv; ++v) {
            marginalFunc.push_back(pConditionalV[v].integral());
        }

        pMarginal.init(marginalFunc.data(), marginalFunc.size(), domain.p_min[1], domain.p_max[1],
                       gpu_dynamic_pointers);
    }

    PBRT_CPU_GPU
    Point2f sample(Point2f u, FloatType *pdf = nullptr, Point2i *offset = nullptr) const {
        FloatType pdfs[2];
        Point2i uv;
        FloatType d1 = pMarginal.sample(u[1], &pdfs[1], &uv[1]);
        FloatType d0 = pConditionalV[uv[1]].sample(u[0], &pdfs[0], &uv[0]);

        if (pdf) {
            *pdf = pdfs[0] * pdfs[1];
        }

        if (offset) {
            *offset = uv;
        }

        return Point2f(d0, d1);
    }

  private:
    Bounds2f domain;
    PiecewiseConstant1D *pConditionalV;
    PiecewiseConstant1D pMarginal;
};