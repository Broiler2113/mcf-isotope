#pragma once
#include <cstdint>
#include <vector>
#include <nlohmann/json.hpp>
#include "layout.hpp"

namespace mcf {
using Json = nlohmann::json;
struct Tensors {
    int canvas = 64;
    size_t count = 0;
    std::vector<float> grid, flat, cand;
    std::vector<int64_t> cells;
};
// The layout is the training ABI. See rl/features.py and the parity harness.
Tensors encode(const Json &request);
int greedy_action(const std::vector<float> &logits, const Tensors &tensors);
}
