#include "ai_kernel.h"
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/templates/sort_array.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using namespace godot;

namespace {
constexpr int32_t FAR = 1 << 20;
constexpr int DX[8] = {-1, 0, 1, -1, 1, -1, 0, 1};
constexpr int DY[8] = {-1, -1, -1, 0, 0, 1, 1, 1};
uint64_t coord_key(const Vector2i &p) {
    return (static_cast<uint64_t>(static_cast<uint32_t>(p.x)) << 32) | static_cast<uint32_t>(p.y);
}
struct Candidate {
    double score;
    int64_t unit;
    Vector2i coord;
};
struct BetterScore {
    bool operator()(const Candidate &a, const Candidate &b) const { return a.score > b.score; }
};
}

// Planning buffers only: no random draws, action execution, or rule mutation.
class MCFAI : public RefCounted {
    GDCLASS(MCFAI, RefCounted);

protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("api_version"), &MCFAI::api_version);
        ClassDB::bind_method(D_METHOD("wave", "width", "height", "mask", "seeds", "must_reach", "extra"), &MCFAI::wave);
        ClassDB::bind_method(D_METHOD("line_targets", "width", "height", "enemies", "xy"), &MCFAI::line_targets);
        ClassDB::bind_method(D_METHOD("assign_candidates", "rows", "gun_spread", "radius", "spread_max", "zone_of", "zone_caps"), &MCFAI::assign_candidates);
        ClassDB::bind_method(D_METHOD("nearest_index", "from", "xy"), &MCFAI::nearest_index);
    }
public:
    int64_t api_version() const { return 1; }

    PackedInt32Array wave(int64_t width, int64_t height, const PackedByteArray &mask,
            const PackedInt32Array &seeds, const PackedInt32Array &must_reach, int64_t extra) const {
        PackedInt32Array result;
        if (width <= 0 || height <= 0 || width > 65536 || height > 65536) return result;
        const int64_t stride = width + 2, size = stride * (height + 2);
        if (size != mask.size() || size > INT32_MAX) return result;
        // The padding is part of the contract; malformed callers cannot make a ray escape it.
        for (int64_t x = 0; x < stride; ++x) {
            if (mask[x] != 2 || mask[size - stride + x] != 2) return result;
        }
        for (int64_t y = 1; y <= height; ++y) {
            if (mask[y * stride] != 2 || mask[y * stride + stride - 1] != 2) return result;
        }
        for (int64_t i = 0; i < seeds.size(); ++i) {
            const int64_t s = seeds[i];
            if (s < stride || s >= size - stride || s % stride == 0 || s % stride == stride - 1) return result;
        }
        for (int64_t i = 0; i < must_reach.size(); ++i) {
            if (must_reach[i] < 0 || must_reach[i] >= size) return result;
        }
        std::vector<uint8_t> visited(mask.ptr(), mask.ptr() + size);
        std::vector<int32_t> distances(size, FAR), queue;
        queue.reserve(width * height);
        for (int64_t i = 0; i < seeds.size(); ++i) {
            const int32_t seed = seeds[i];
            if (visited[seed] == 1) continue;
            visited[seed] = 1;
            distances[seed] = 0;
            queue.push_back(seed);
        }
        const int64_t offsets[8] = {-stride - 1, -stride, -stride + 1, -1, 1, stride - 1, stride, stride + 1};
        int64_t head = 0, layer_end = must_reach.is_empty() ? -1 : static_cast<int64_t>(queue.size());
        int64_t cap = FAR;
        while (head < static_cast<int64_t>(queue.size())) {
            if (head == layer_end) {
                layer_end = queue.size();
                if (cap == FAR) {
                    bool reached = true;
                    for (int64_t i = 0; i < must_reach.size(); ++i) reached = reached && distances[must_reach[i]] != FAR;
                    if (reached) cap = distances[queue[head]] + extra;
                }
            }
            const int32_t current = queue[head++], next_distance = distances[current] + 1;
            if (next_distance > cap) break;
            for (const int64_t offset : offsets) {
                const int64_t next = current + offset;
                if (visited[next] != 0) continue;
                visited[next] = 1;
                distances[next] = next_distance;
                queue.push_back(static_cast<int32_t>(next));
            }
        }
        result.resize(width * height);
        int32_t *output = result.ptrw();
        for (int64_t y = 0; y < height; ++y) {
            std::copy_n(distances.data() + (y + 1) * stride + 1, width, output + y * width);
        }
        return result;
    }

    Dictionary line_targets(int64_t width, int64_t height, const Array &enemies, const PackedInt32Array &xy) const {
        Dictionary result;
        if (width <= 0 || height <= 0 || width > 65536 || height > 65536 || width * height > INT32_MAX || xy.size() != enemies.size() * 2) return result;
        std::vector<std::vector<int64_t>> targets(width * height);
        std::vector<int64_t> order;
        for (int64_t e = 0; e < enemies.size(); ++e) {
            const int64_t ex = xy[e * 2], ey = xy[e * 2 + 1];
            if (ex < 0 || ey < 0 || ex >= width || ey >= height) return Dictionary();
            for (int dir = 0; dir < 8; ++dir) {
                int64_t x = ex + DX[dir], y = ey + DY[dir];
                while (x >= 0 && y >= 0 && x < width && y < height) {
                    const int64_t index = y * width + x;
                    if (targets[index].empty()) order.push_back(index);
                    targets[index].push_back(e);
                    x += DX[dir];
                    y += DY[dir];
                }
            }
        }
        for (const int64_t index : order) {
            Array entries;
            entries.resize(targets[index].size());
            for (size_t i = 0; i < targets[index].size(); ++i) entries[i] = enemies[targets[index][i]];
            result[Vector2i(index % width, index / width)] = entries;
        }
        return result;
    }

    Array assign_candidates(const Array &rows, bool gun_spread, int64_t radius, int64_t spread_max,
            const Dictionary &zone_of, const Array &zone_caps) const {
        Array result;
        if (radius < 0 || radius > 256) return result;
        std::vector<Candidate> candidates;
        candidates.reserve(rows.size());
        for (int64_t i = 0; i < rows.size(); ++i) {
            if (rows[i].get_type() != Variant::ARRAY) return result;
            const Array row = rows[i];
            if (row.size() != 3 || row[2].get_type() != Variant::VECTOR2I || row[1].get_type() != Variant::INT) return result;
            const double score = row[0];
            if (!std::isfinite(score)) return result;
            candidates.push_back({score, row[1], row[2]});
        }
        // Match Array.sort_custom's introsort, including the order of equal-score rows.
        SortArray<Candidate, BetterScore> sorter;
        sorter.sort(candidates.data(), candidates.size());
        std::unordered_set<int64_t> assigned;
        std::unordered_set<uint64_t> taken;
        std::unordered_map<uint64_t, int64_t> shell_reach;
        std::unordered_map<int64_t, int64_t> in_zone;
        Dictionary destinations, scores;
        for (const Candidate &row : candidates) {
            if (assigned.count(row.unit)) continue;
            const uint64_t key = coord_key(row.coord);
            if (taken.count(key)) continue;
            if (gun_spread && shell_reach[key] > spread_max) continue;
            if (gun_spread) {
                // Deliberately before the zone-cap check: preserve existing planner ordering.
                for (int64_t y = -radius; y <= radius; ++y) {
                    for (int64_t x = -radius; x <= radius; ++x) {
                        if (std::abs(x) + std::abs(y) <= radius) ++shell_reach[coord_key(row.coord + Vector2i(x, y))];
                    }
                }
            }
            const int64_t zone = zone_of.get(row.coord, -1);
            if (zone >= 0 && zone < zone_caps.size() && in_zone[zone] >= static_cast<int64_t>(zone_caps[zone])) continue;
            if (zone >= 0) ++in_zone[zone];
            taken.insert(key);
            assigned.insert(row.unit);
            destinations[row.unit] = row.coord;
            scores[row.unit] = row.score;
        }
        result.push_back(destinations);
        result.push_back(scores);
        return result;
    }

    int64_t nearest_index(const Vector2i &from, const PackedInt32Array &xy) const {
        int64_t best = -1, distance = int64_t(1) << 30;
        if (xy.size() % 2 != 0) return -1;
        for (int64_t i = 0; i < xy.size(); i += 2) {
            const int64_t dx = std::abs(static_cast<int64_t>(from.x) - xy[i]);
            const int64_t dy = std::abs(static_cast<int64_t>(from.y) - xy[i + 1]);
            const int64_t d = std::max(dx, dy);
            if (d < distance) { distance = d; best = i / 2; }
        }
        return best;
    }
};

void register_ai_kernel() { ClassDB::register_class<MCFAI>(); }
