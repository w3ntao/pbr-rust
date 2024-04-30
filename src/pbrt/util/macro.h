#pragma once

#include <iostream>

#define PBRT_CPU_GPU __host__ __device__
#define PBRT_GPU __device__

using FloatType = float;

namespace HIDDEN {
static void _check_cuda_error(cudaError_t error_code, char const *const func,
                              const char *const file, int const line) {
    if (!error_code) {
        return;
    }

    std::cerr << "CUDA error at " << file << ": " << line << " '" << func << "'\n";
    auto error_str = cudaGetErrorString(error_code);
    std::cerr << "CUDA error " << static_cast<unsigned int>(error_code) << ": " << error_str
              << "\n";

    // Make sure we call CUDA Device Reset before exiting
    cudaDeviceReset();
    exit(1);
}

PBRT_CPU_GPU
static void _report_error(const char *file_name, const char *func_name, uint line_num) {
    printf("\nERROR: %s: %s(): line %d: unreachable branch\n\n", file_name, func_name, line_num);

#if defined(__CUDA_ARCH__)
    asm("trap;");
#else
    exit(1);
#endif
}

} // namespace HIDDEN

// limited version of checkCudaErrors from helper_cuda.h in CUDA examples
#define CHECK_CUDA_ERROR(val) HIDDEN::_check_cuda_error((val), #val, __FILE__, __LINE__)

#define REPORT_FATAL_ERROR() HIDDEN::_report_error(__FILE__, __func__, __LINE__)

static const bool DEBUGGING = true;
