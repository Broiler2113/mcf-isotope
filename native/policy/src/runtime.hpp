#pragma once
#include "features.hpp"
#include <onnxruntime_cxx_api.h>
#include <memory>

namespace mcf {
struct Prediction { int action; float value; std::vector<float> logits; };
class Runtime {
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "MCFPolicy"};
    Ort::SessionOptions options;
    std::unique_ptr<Ort::Session> session;
    Ort::MemoryInfo memory{Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault)};
public:
    Runtime(const void *data, size_t size);
    Json metadata() const;
    Prediction infer(Tensors &t);
};
}
