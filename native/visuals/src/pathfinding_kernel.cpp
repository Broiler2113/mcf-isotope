#include "pathfinding_kernel.h"
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

using namespace godot;

// Mechanically equivalent to Movement.reachable. Frontier order and dictionary
// insertion order are part of AI behavior, not interchangeable implementation details.
class MCFPathfinding : public RefCounted {
    GDCLASS(MCFPathfinding, RefCounted)
    enum Flag { WALKABLE = 1, OCCUPIED = 2, HARD_BLOCKED = 4, AIRLOCK = 8, HEDGEHOG = 16, FIRE = 32, CORPSES = 64 };
    static constexpr int64_t TOMB = int64_t(1) << 30;
protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("api_version"), &MCFPathfinding::api_version);
        ClassDB::bind_method(D_METHOD("reachable", "size", "start", "budget", "flags", "heights", "options"), &MCFPathfinding::reachable);
    }
public:
    int64_t api_version() const { return 1; }

    Array reachable(const Vector2i &size, const Vector2i &start, int64_t budget,
                    const PackedByteArray &flags, const PackedFloat64Array &heights,
                    const Dictionary &options) const {
        const int64_t count = int64_t(size.x) * size.y;
        const int64_t flat = options.get("flat", 1), jump = options.get("jump", 2);
        // Decline malformed/unsupported inputs without mutating the caller's state.
        if (size.x <= 0 || size.y <= 0 || count > std::numeric_limits<int32_t>::max() ||
                flags.size() != count || heights.size() != count || flat <= 0 || jump <= 0 ||
                flat >= TOMB || jump >= TOMB || budget >= TOMB) return Array();
        Dictionary cost, came;
        Array result;
        result.push_back(cost);
        result.push_back(came);
        if (start.x < 0 || start.y < 0 || start.x >= size.x || start.y >= size.y || budget < 0) return result;

        const bool avoid_fire = options.get("avoid_fire", false);
        const Dictionary avoid = options.get("avoid", Dictionary());
        const Dictionary free = options.get("free", Dictionary());
        const Dictionary climb = options.get("climb", Dictionary());
        // The bounded snapshot relies on positive integral movement costs. A
        // future rule with free/negative steps uses the script reference instead.
        const Array climb_values = climb.values();
        for (int64_t i = 0; i < climb_values.size(); ++i) {
            const Variant value = climb_values[i];
            if (value.get_type() == Variant::NIL) continue;
            if (value.get_type() != Variant::INT && value.get_type() != Variant::FLOAT) return Array();
            const double raw = value;
            if (!std::isfinite(raw) || raw < 1.0 || raw >= TOMB) return Array();
        }
        const Vector2i stop = options.get("stop", Vector2i(-1, -1));
        const bool partial = stop != Vector2i(-1, -1);
        const bool has_free = !free.is_empty(), has_avoid = !avoid.is_empty();
        // Movement's snapshot uses this same conservative bound. Scratch memory is
        // proportional to the local search area rather than the complete map.
        const int64_t radius = budget * (jump == 1 ? 2 : 1);
        const int x0 = static_cast<int>(std::max<int64_t>(0, int64_t(start.x) - radius));
        const int y0 = static_cast<int>(std::max<int64_t>(0, int64_t(start.y) - radius));
        const int x1 = static_cast<int>(std::min<int64_t>(size.x, int64_t(start.x) + radius + 1));
        const int y1 = static_cast<int>(std::min<int64_t>(size.y, int64_t(start.y) + radius + 1));
        const int sw = x1 - x0;
        const size_t search_count = size_t(sw) * (y1 - y0);
        std::vector<int64_t> distances(search_count, -1), diagonals(search_count, 0), slots(search_count, -1);
        const auto local = [x0, y0, sw](const Vector2i &p) { return size_t(p.y - y0) * sw + (p.x - x0); };
        const auto inside = [&size](const Vector2i &p) { return p.x >= 0 && p.y >= 0 && p.x < size.x && p.y < size.y; };
        const auto index = [&size](const Vector2i &p) { return int64_t(p.y) * size.x + p.x; };
        const uint8_t *f = flags.ptr();
        const double *h = heights.ptr();
        std::vector<Vector2i> frontier{start};
        std::vector<int64_t> fcost{0};
        distances[local(start)] = 0;
        slots[local(start)] = 0;
        cost[start] = int64_t(0);
        size_t first = 0, live = 1;
        int64_t low = 0;
        const Vector2i offsets[] = {{-1,-1}, {0,-1}, {1,-1}, {-1,0}, {1,0}, {-1,1}, {0,1}, {1,1}};
        while (live > 0) {
            while (fcost[first] == TOMB) ++first;
            size_t best = first;
            int64_t best_cost = fcost[first];
            for (size_t i = first + 1; i < fcost.size() && best_cost > low; ++i) {
                if (fcost[i] < best_cost) { best_cost = fcost[i]; best = i; }
            }
            low = best_cost;
            const Vector2i current = frontier[best];
            const size_t current_slot = local(current);
            fcost[best] = TOMB;
            --live;
            slots[current_slot] = -1;
            if (partial && current == stop) break;
            const int64_t current_index = index(current);
            if (avoid_fire && (f[current_index] & FIRE) && current != start) continue;
            const double from_height = h[current_index];
            for (const Vector2i &delta : offsets) {
                const Vector2i next = current + delta;
                if (!inside(next)) continue;
                const int64_t ni = index(next);
                const uint8_t nf = f[ni];
                int64_t step = -1;
                if ((nf & WALKABLE) && !(nf & (HARD_BLOCKED | CORPSES)) && (!(nf & OCCUPIED) || (has_free && free.has(next)))) {
                    if (nf & AIRLOCK) step = flat;
                    else if (h[ni] > from_height) {
                        const Variant climbing = climb.get(h[ni], Variant());
                        step = climbing.get_type() == Variant::NIL ? flat : int64_t(climbing);
                    }
                    else step = flat;
                }
                Vector2i dest = next;
                if (nf & HEDGEHOG) {
                    dest += delta;
                    if (!inside(dest)) continue;
                    const uint8_t landing = f[index(dest)];
                    // Landing deliberately does not honor free_cells, matching Grid.blocks_walk.
                    if (!(landing & WALKABLE) || (landing & (HARD_BLOCKED | OCCUPIED))) continue;
                    step = jump;
                } else if (step < 0) continue;
                if (has_avoid && avoid.has(dest)) continue;
                const int64_t new_cost = best_cost + step;
                if (new_cost > budget) continue;
                // Positive move costs guarantee every accepted destination is in the
                // prepared rectangle, even when jumping over a hedgehog.
                if (dest.x < x0 || dest.y < y0 || dest.x >= x1 || dest.y >= y1) return Array();
                const size_t at = local(dest);
                const int64_t previous = distances[at];
                const int64_t nd = diagonals[current_slot] + (delta.x != 0 && delta.y != 0 ? 1 : 0);
                if (previous >= 0 && new_cost == previous && nd < diagonals[at]) {
                    came[dest] = current;
                    diagonals[at] = nd;
                    continue;
                }
                if (previous < 0 || new_cost < previous) {
                    distances[at] = new_cost;
                    cost[dest] = new_cost;
                    came[dest] = current;
                    diagonals[at] = nd;
                    if (slots[at] >= 0) fcost[size_t(slots[at])] = new_cost;
                    else {
                        slots[at] = static_cast<int64_t>(frontier.size());
                        frontier.push_back(dest);
                        fcost.push_back(new_cost);
                        ++live;
                    }
                }
            }
        }
        cost.erase(start);
        return result;
    }
};

void register_pathfinding_kernel() { ClassDB::register_class<MCFPathfinding>(); }
