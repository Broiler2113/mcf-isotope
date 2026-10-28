#include "ai_kernel.h"
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/templates/sort_array.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
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
        ClassDB::bind_method(D_METHOD("line_slots", "from", "xy"), &MCFAI::line_slots);
        ClassDB::bind_method(D_METHOD("near_slots", "at", "xy", "radius"), &MCFAI::near_slots);
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

    // GameState.slots_on_lines: the rows (x, y per unit) on a firing line from `from` (its row,
    // column or a diagonal; `from` itself is not), in row order.
    PackedInt32Array line_slots(const Vector2i &from, const PackedInt32Array &xy) const {
        PackedInt32Array result;
        if (xy.size() % 2 != 0) return result;
        for (int64_t i = 0; i < xy.size(); i += 2) {
            const int64_t dx = static_cast<int64_t>(xy[i]) - from.x;
            const int64_t dy = static_cast<int64_t>(xy[i + 1]) - from.y;
            if ((dx == 0 && dy == 0) || (dx != 0 && dy != 0 && std::abs(dx) != std::abs(dy))) continue;
            result.push_back(static_cast<int32_t>(i / 2));
        }
        return result;
    }

    // GameState.slots_near: the rows within `radius` cells of `at` (Chebyshev; `at` itself is
    // not), in row order.
    PackedInt32Array near_slots(const Vector2i &at, const PackedInt32Array &xy, int64_t radius) const {
        PackedInt32Array result;
        if (xy.size() % 2 != 0 || radius < 0) return result;
        for (int64_t i = 0; i < xy.size(); i += 2) {
            const int64_t dx = std::abs(static_cast<int64_t>(xy[i]) - at.x);
            const int64_t dy = std::abs(static_cast<int64_t>(xy[i + 1]) - at.y);
            if (dx > radius || dy > radius || (dx == 0 && dy == 0)) continue;
            result.push_back(static_cast<int32_t>(i / 2));
        }
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

// One AI staff plan, natively: the threat map (AIPlanner._build_exposure's rays) and the cell
// score (AIPlanner._score_cell) of every soldier but marksmen. The same terms, in the same order
// and in doubles, so each sum equals the GDScript one bit for bit; pow() never runs here (its
// results come in a table computed by the engine). set_board() takes AIPlanner._scoring_board
// bits and the vehicle cells, exposure() walks the rays, setup() takes the plan's maps; for each
// soldier targets() names the enemies whose futility GDScript must still answer (shot_is_futile
// is measured from the soldier's own cell, not the cell being rated), then score() rates cells.
class MCFPlanScorer : public RefCounted {
    GDCLASS(MCFPlanScorer, RefCounted);

    // AIPlanner.SB_* bits.
    static constexpr int32_t WALL = 1, COVER = 2, SHELTER = 4, TRENCH = 8, HEDGEHOG = 16,
            DOT_OPEN = 32, FIRE = 64, SPREAD = 128, OBSCURED = 256, GLASS = 512, COVER_SHIFT = 12, SHIELD_SHIFT = 15;
    static constexpr int32_t ABILITY_AT = 1, ABILITY_MINER = 2, ABILITY_MARKSMAN = 3;
    // AIPlanner.SL_*: what a marksman's beam meets in a cell (kind in bits 0-2, value above).
    static constexpr int32_t L_NONE = 0, L_STOP = 1, L_FURNITURE = 2, L_GLASS = 3, L_BOX = 4, L_FIXED = 5, L_WALL = 6;
    // AIPlanner.SO_*: the cell's occupant.
    static constexpr int32_t OCC_ALIVE = 1, OCC_FIELD = 2, OCC_SHIELD = 4, OCC_CORPSE = 8;
    // Beam records, as GameActionResolver._laser_trace's "kind".
    enum BeamKind { B_EMPTY = 0, B_TERRAIN = 1, B_VEHICLE = 2, B_SHIELD = 3, B_UNIT = 4, B_FEATURE = 5 };
    struct BeamRec {
        int64_t x, y, kind, cost, damage, vehicle, left;
        bool destroyed, stop;
    };

    int64_t w = 0, h = 0;
    bool board = false, units = false, ready = false, classic = true, spread = false;
    std::vector<int32_t> laser, occupant, cover_vid, cover_dur;
    int64_t k_potential = 0, k_per_durability = 1, k_kill = 0, k_kill_corpse = 0, k_shield = 0,
            k_terrain_wall = 0, k_obscured = 0, k_glass_every = 1, k_glass_recharge = 0;
    mutable std::unordered_map<int64_t, std::vector<BeamRec>> beams;
    std::vector<int32_t> flags, vehicle, geo, exposed, ally, lane_start, lane_ids, ex, ey, vx, vy, vstart, vids;
    std::vector<double> threat, veh_close, evalue;
    std::vector<uint8_t> zone, tank;
    double w_fire = 0, w_ease = 0, w_adv = 0, w_cover = 0, w_trench = 0, w_danger = 0, w_threat = 0,
            w_shelter = 0, w_obj = 0, w_zone = 0, w_step = 0, obj_share = 0, w_spread = 0,
            w_lane_block = 0, w_lane_clear = 0, w_tank_path = 0, w_veh_fire = 0;
    int64_t at_min_range = 0, smoke_penalty = 0, geo_far = 0;

    static int64_t sign(int64_t v) { return (v > 0) - (v < 0); }
    bool on_board(int64_t x, int64_t y) const { return x >= 0 && y >= 0 && x < w && y < h; }
    static bool on_line(int64_t ax, int64_t ay, int64_t bx, int64_t by) {
        const int64_t dx = bx - ax, dy = by - ay;
        if (dx == 0 && dy == 0) return false;
        return dx == 0 || dy == 0 || std::abs(dx) == std::abs(dy);
    }
    // Combat.hit_number.
    static int64_t hit_number(int64_t dist, double range) {
        if (range <= 0.0) return 7;
        const int64_t x = static_cast<int64_t>(std::ceil(static_cast<double>(dist) / (range / 6.0)));
        return std::clamp<int64_t>(x, 1, 7);
    }
    // GameActionResolver.los_blocked with ignore_units and no glass; gas only when it blocks.
    bool line_blocked(int64_t fx, int64_t fy, int64_t tx, int64_t ty, bool allow_embrasure, bool gas) const {
        if (!on_board(fx, fy) || !on_board(tx, ty)) return false;
        const int64_t dx = tx - fx, dy = ty - fy;
        if (dx == 0 && dy == 0) return false;
        if (dx != 0 && dy != 0 && std::abs(dx) != std::abs(dy)) return false;
        const int64_t sx = sign(dx), sy = sign(dy), from = fy * w + fx, to = ty * w + tx;
        if (gas && ((flags[from] & OBSCURED) || (flags[to] & OBSCURED))) return true;
        int64_t x = fx + sx, y = fy + sy, d = 1;
        while (x != tx || y != ty) {
            const int64_t i = y * w + x;
            const int32_t f = flags[i];
            if (gas && (f & OBSCURED)) return true;
            if (f & WALL) {
                if (!(d <= 1 && ((f & HEDGEHOG) || (allow_embrasure && (f & DOT_OPEN))))) return true;
            } else if (vehicle[i] != -1 && vehicle[i] != vehicle[from] && vehicle[i] != vehicle[to]) {
                return true;
            }
            x += sx;
            y += sy;
            ++d;
        }
        return false;
    }
    // los_blocked(from, to, allow_embrasure = true, ignore_units = false, glass_passable = true):
    // a civilian's sight. Gas blocks; a living unit on the way blocks.
    bool sight_blocked(int64_t fx, int64_t fy, int64_t tx, int64_t ty, const std::vector<uint8_t> &alive) const {
        const int64_t dx = tx - fx, dy = ty - fy;
        if (dx == 0 && dy == 0) return false;
        if (dx != 0 && dy != 0 && std::abs(dx) != std::abs(dy)) return false;
        const int64_t sx = sign(dx), sy = sign(dy), from = fy * w + fx, to = ty * w + tx;
        if ((flags[from] & OBSCURED) || (flags[to] & OBSCURED)) return true;
        int64_t x = fx + sx, y = fy + sy, d = 1;
        while (x != tx || y != ty) {
            const int64_t i = y * w + x;
            const int32_t f = flags[i];
            if (f & OBSCURED) return true;
            if (f & WALL) {
                if (!((d <= 1 && (f & (HEDGEHOG | DOT_OPEN))) || (f & GLASS))) return true;
            } else if (vehicle[i] != -1 && vehicle[i] != vehicle[from] && vehicle[i] != vehicle[to]) {
                return true;
            } else if (alive[i]) {
                return true;
            }
            x += sx;
            y += sy;
            ++d;
        }
        return false;
    }
    // civilians_seeing's body: each sleeper against every target on one of its lines (a few
    // sleepers are asked on most actions, so no per-line index is built).
    PackedByteArray sight_check(const PackedInt32Array &sleepers, const std::vector<int32_t> &t,
            const PackedInt32Array &occupied) const {
        PackedByteArray result;
        std::vector<uint8_t> alive(w * h, 0);
        for (int64_t i = 0; i < occupied.size(); ++i) {
            if (occupied[i] < 0 || occupied[i] >= w * h) return result;
            alive[occupied[i]] = 1;
        }
        for (size_t k = 0; k < t.size(); k += 2) {
            if (!on_board(t[k], t[k + 1])) return result;
        }
        result.resize(sleepers.size() / 2);
        for (int64_t s = 0; s < sleepers.size(); s += 2) {
            const int64_t cx = sleepers[s], cy = sleepers[s + 1];
            if (!on_board(cx, cy)) return PackedByteArray();
            bool sees = false;
            for (size_t k = 0; k < t.size() && !sees; k += 2) {
                const int64_t tx = t[k], ty = t[k + 1];
                sees = on_line(cx, cy, tx, ty) && !sight_blocked(cx, cy, tx, ty, alive);
            }
            result.set(s / 2, sees ? 1 : 0);
        }
        return result;
    }
    // GameActionResolver.gas_blocks_line: the same Bresenham walk, both ends included.
    bool gas_on_line(int64_t ax, int64_t ay, int64_t bx, int64_t by) const {
        if (ax == bx && ay == by) return false;
        const int64_t dx = std::abs(bx - ax), dy = std::abs(by - ay);
        const int64_t sx = ax < bx ? 1 : -1, sy = ay < by ? 1 : -1;
        int64_t err = dx - dy, x = ax, y = ay;
        while (true) {
            if (flags[y * w + x] & OBSCURED) return true;
            if (x == bx && y == by) return false;
            const int64_t e2 = 2 * err;
            if (e2 > -dy) { err -= dy; x += sx; }
            if (e2 < dx) { err += dx; y += sy; }
        }
    }
    // AIPlanner._fire_ease for a soldier who is not a marksman. -2: everything but the
    // futility check passed and futile is null (targets()).
    double ease(int64_t fx, int64_t fy, int64_t e, double range, const uint8_t *futile) const {
        const int64_t tx = ex[e], ty = ey[e];
        if (fx == tx && fy == ty) return -1.0;
        const int64_t dist = std::max(std::abs(fx - tx), std::abs(fy - ty));
        int64_t need = hit_number(dist, range);
        if (need >= 7) return -1.0;
        if ((flags[ty * w + tx] & TRENCH) && dist > 1) return -1.0;
        if (line_blocked(fx, fy, tx, ty, true, false)) return -1.0;
        if (gas_on_line(fx, fy, tx, ty)) need += smoke_penalty;
        if (need >= 7) return -1.0;
        if (futile == nullptr) return -2.0;
        if (futile[e]) return -1.0;
        return static_cast<double>(std::clamp<int64_t>(7 - need, 0, 6));
    }
    // trench_protected(from, target, flat_beam = true).
    bool trench_protects_flat(int64_t fx, int64_t fy, int64_t tx, int64_t ty) const {
        const bool target_in = flags[ty * w + tx] & TRENCH;
        if (!on_board(fx, fy) || !(flags[fy * w + fx] & TRENCH)) return target_in;
        if (!target_in) return true;   // from the bottom of a trench the beam cannot climb out
        // _trench_run_clear: a straight line, trench on every cell between.
        const int64_t dx = tx - fx, dy = ty - fy;
        if ((dx == 0 && dy == 0) || (dx != 0 && dy != 0 && std::abs(dx) != std::abs(dy))) return true;
        const int64_t sx = sign(dx), sy = sign(dy);
        for (int64_t x = fx + sx, y = fy + sy; x != tx || y != ty; x += sx, y += sy) {
            if (!on_board(x, y) || !(flags[y * w + x] & TRENCH)) return true;
        }
        return false;
    }
    // GameActionResolver._laser_trace, cached per cell and direction for the plan (the board
    // stands still while it is made), like AIPlanner._beam_traces.
    const std::vector<BeamRec> &beam_trace(int64_t fx, int64_t fy, int64_t sx, int64_t sy) const {
        const int64_t key = ((fy * w + fx) * 3 + (sx + 1)) * 3 + (sy + 1);
        auto found = beams.find(key);
        if (found != beams.end()) return found->second;
        std::vector<BeamRec> &out = beams[key];
        if (sx == 0 && sy == 0) return out;
        int64_t potential = k_potential, glass_hits = 0, x = fx + sx, y = fy + sy;
        const bool from_in_trench = on_board(fx, fy) && (flags[fy * w + fx] & TRENCH);
        while (on_board(x, y) && potential > 0) {
            const int64_t i = y * w + x;
            const int32_t f = flags[i], l = laser[i], kind = l & 7, value = l >> 3, o = occupant[i];
            BeamRec rec{x, y, B_EMPTY, 0, 0, -1, potential, false, false};
            if ((from_in_trench && !(f & TRENCH)) || kind == L_STOP) {
                rec.kind = B_TERRAIN;
                rec.stop = true;
                out.push_back(rec);
                break;
            }
            if ((o & OCC_ALIVE) && trench_protects_flat(fx, fy, x, y)) {
                out.push_back(rec);   // over the trench: nothing spent
                x += sx;
                y += sy;
                continue;
            }
            if (cover_vid[i] != -1) {
                const int64_t dur = cover_dur[i], full = dur * k_per_durability;
                rec.kind = B_VEHICLE;
                rec.vehicle = cover_vid[i];
                rec.stop = true;
                if (potential >= full) {
                    rec.cost = full;
                    rec.damage = dur;
                    rec.destroyed = true;
                } else {
                    rec.cost = potential;
                    rec.damage = potential / k_per_durability;
                }
            } else if (o & OCC_FIELD) {
                if (o & OCC_SHIELD) {
                    rec.kind = B_SHIELD;
                    rec.stop = true;
                    rec.cost = std::min(potential, k_shield);
                    rec.destroyed = potential >= k_shield;
                } else {
                    const int64_t kill = (o & OCC_CORPSE) ? k_kill_corpse : k_kill;
                    rec.kind = B_UNIT;
                    if (potential >= kill) {
                        rec.cost = kill;
                        rec.destroyed = true;
                    } else {
                        rec.stop = true;
                    }
                }
            } else if (kind == L_FURNITURE || kind == L_FIXED || kind == L_WALL) {
                const int64_t cost = kind == L_WALL ? k_terrain_wall : value;
                rec.kind = kind == L_WALL ? B_TERRAIN : B_FEATURE;
                if (potential >= cost) {
                    rec.cost = cost;
                    rec.destroyed = true;
                } else {
                    rec.stop = true;
                }
            } else if (kind == L_GLASS) {
                rec.kind = B_FEATURE;
                ++glass_hits;
                rec.destroyed = true;
                if (glass_hits % k_glass_every == 0) rec.cost = -k_glass_recharge;
            } else if (kind == L_BOX) {
                const int64_t cracks = std::min<int64_t>(value, potential / k_per_durability);
                rec.kind = B_FEATURE;
                rec.cost = cracks * k_per_durability;
                rec.destroyed = cracks >= value;
                rec.stop = !rec.destroyed;
            }
            if ((f & OBSCURED) && !rec.stop) rec.cost += std::min(k_obscured, potential - rec.cost);
            if (rec.stop && rec.cost == 0) break;
            potential -= rec.cost;
            rec.left = potential;
            out.push_back(rec);
            if (rec.stop) break;
            x += sx;
            y += sy;
        }
        return out;
    }
    // AIPlanner._beam_kills.
    bool beam_kills(int64_t fx, int64_t fy, int64_t tx, int64_t ty) const {
        for (const BeamRec &rec : beam_trace(fx, fy, sign(tx - fx), sign(ty - fy))) {
            if (rec.x == tx && rec.y == ty) return (rec.kind == B_UNIT || rec.kind == B_SHIELD) && rec.destroyed;
        }
        return false;
    }
    // AIPlanner._beam_burns.
    bool beam_burns(int64_t fx, int64_t fy, int64_t ax, int64_t ay, int64_t vid) const {
        for (const BeamRec &rec : beam_trace(fx, fy, sign(ax - fx), sign(ay - fy))) {
            if (rec.kind == B_VEHICLE && rec.vehicle == vid) return rec.damage > 0;
        }
        return false;
    }
    // AIPlanner._fire_ease for a marksman: no range cut-off and no wall check, the beam decides.
    double ease_marksman(int64_t fx, int64_t fy, int64_t e, double range, const uint8_t *futile) const {
        const int64_t tx = ex[e], ty = ey[e];
        if (fx == tx && fy == ty) return -1.0;
        const int64_t dist = std::max(std::abs(fx - tx), std::abs(fy - ty));
        int64_t need = hit_number(dist, range);
        if (trench_protects_flat(fx, fy, tx, ty)) return -1.0;
        if (gas_on_line(fx, fy, tx, ty)) need += smoke_penalty;
        if (futile == nullptr) return -2.0;
        if (futile[e]) return -1.0;
        if (!beam_kills(fx, fy, tx, ty)) return -1.0;
        return static_cast<double>(std::clamp<int64_t>(7 - need, 0, 6));
    }
    bool fire_near(int64_t x, int64_t y) const {
        if (flags[y * w + x] & FIRE) return true;
        for (int64_t ny = y - 1; ny <= y + 1; ++ny) {
            if (ny < 0 || ny >= h) continue;
            for (int64_t nx = x - 1; nx <= x + 1; ++nx) {
                if (nx < 0 || nx >= w) continue;
                if (flags[ny * w + nx] & FIRE) return true;
            }
        }
        return false;
    }
    // AIController.fire_creeps.
    bool fire_creeps(int64_t x, int64_t y) const {
        if (!(flags[y * w + x] & SPREAD)) return false;
        static constexpr int DX2[8] = {2, -2, 0, 0, 1, 1, -1, -1};
        static constexpr int DY2[8] = {0, 0, 2, -2, 1, -1, 1, -1};
        for (int k = 0; k < 8; ++k) {
            const int64_t sx = x + DX2[k], sy = y + DY2[k];
            if (!on_board(sx, sy) || !(flags[sy * w + sx] & FIRE)) continue;
            const int64_t mids[2][2] = {{x + sign(DX2[k]), y}, {x, y + sign(DY2[k])}};
            for (const auto &mid : mids) {
                if (mid[0] == x && mid[1] == y) continue;
                if (!on_board(mid[0], mid[1])) continue;
                const int32_t mf = flags[mid[1] * w + mid[0]];
                if ((mf & FIRE) || (mf & SPREAD)) return true;
            }
        }
        return false;
    }
    double shelter(int64_t x, int64_t y) const {
        int64_t covered = 0;
        for (int k = 0; k < 8; ++k) {
            const int64_t nx = x + DX[k], ny = y + DY[k];
            if (on_board(nx, ny) && (flags[ny * w + nx] & SHELTER)) ++covered;
        }
        return static_cast<double>(covered) / 8.0;
    }
    // AIPlanner._vehicle_fire_value: the anti-tank gunner's round or the marksman's beam.
    double vehicle_fire_value(int64_t x, int64_t y, double range, int64_t ability) const {
        double value = 0.0;
        for (size_t v = 0; v + 1 < vstart.size(); ++v) {
            for (int32_t k = vstart[v]; k < vstart[v + 1]; ++k) {
                const int64_t fx = vx[k], fy = vy[k];
                if (!on_line(x, y, fx, fy)) continue;
                if (ability == ABILITY_AT) {
                    const int64_t d = std::max(std::abs(x - fx), std::abs(y - fy));
                    if (d < at_min_range || hit_number(d, range) >= 7 || line_blocked(x, y, fx, fy, false, true)) continue;
                } else if (!beam_burns(x, y, fx, fy, vids[v])) {
                    continue;
                }
                value += w_veh_fire;
                break;
            }
        }
        return value;
    }
    static bool read_ints(const Dictionary &d, const char *key, std::vector<int32_t> &out) {
        if (d.get(key, Variant()).get_type() != Variant::PACKED_INT32_ARRAY) return false;
        const PackedInt32Array a = d[key];
        out.assign(a.ptr(), a.ptr() + a.size());
        return true;
    }
    static bool read_doubles(const Dictionary &d, const char *key, std::vector<double> &out) {
        if (d.get(key, Variant()).get_type() != Variant::PACKED_FLOAT64_ARRAY) return false;
        const PackedFloat64Array a = d[key];
        out.assign(a.ptr(), a.ptr() + a.size());
        return true;
    }
    bool sparse_ints(const Dictionary &d, const char *cells_key, const char *values_key, std::vector<int32_t> &dense, int32_t fill) const {
        std::vector<int32_t> cells, values;
        if (!read_ints(d, cells_key, cells) || (values_key && !read_ints(d, values_key, values))) return false;
        if (values_key && values.size() != cells.size()) return false;
        dense.assign(w * h, fill);
        for (size_t i = 0; i < cells.size(); ++i) {
            if (cells[i] < 0 || cells[i] >= w * h) return false;
            dense[cells[i]] = values_key ? values[i] : 1;
        }
        return true;
    }
    bool sparse_doubles(const Dictionary &d, const char *cells_key, const char *values_key, std::vector<double> &dense) const {
        std::vector<int32_t> cells;
        std::vector<double> values;
        if (!read_ints(d, cells_key, cells) || !read_doubles(d, values_key, values) || values.size() != cells.size()) return false;
        dense.assign(w * h, 0.0);
        for (size_t i = 0; i < cells.size(); ++i) {
            if (cells[i] < 0 || cells[i] >= w * h) return false;
            dense[cells[i]] = values[i];
        }
        return true;
    }
    bool cells_ok(const PackedInt32Array &cells) const {
        for (int64_t i = 0; i < cells.size(); ++i) {
            if (cells[i] < 0 || cells[i] >= w * h) return false;
        }
        return true;
    }

protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("api_version"), &MCFPlanScorer::api_version);
        ClassDB::bind_method(D_METHOD("set_board", "board"), &MCFPlanScorer::set_board);
        ClassDB::bind_method(D_METHOD("set_units", "units"), &MCFPlanScorer::set_units);
        ClassDB::bind_method(D_METHOD("beam", "from", "step"), &MCFPlanScorer::beam);
        ClassDB::bind_method(D_METHOD("smoke_values", "smoke"), &MCFPlanScorer::smoke_values);
        ClassDB::bind_method(D_METHOD("civilians_seeing", "sleepers", "targets", "occupied"), &MCFPlanScorer::civilians_seeing);
        ClassDB::bind_method(D_METHOD("civilians_seeing_rows", "sleepers", "xy", "kinds", "hulls", "occupied"), &MCFPlanScorer::civilians_seeing_rows);
        ClassDB::bind_method(D_METHOD("exposure", "threats", "ranges", "hit_table", "classic", "threat_seed"), &MCFPlanScorer::exposure);
        ClassDB::bind_method(D_METHOD("setup", "plan"), &MCFPlanScorer::setup);
        ClassDB::bind_method(D_METHOD("targets", "range", "fireproof", "marksman", "cells"), &MCFPlanScorer::targets);
        ClassDB::bind_method(D_METHOD("score", "soldier", "cells", "steps", "futile"), &MCFPlanScorer::score);
    }

public:
    int64_t api_version() const { return 1; }

    // Each returns false (or an empty result) on malformed input: the caller keeps GDScript.
    bool set_board(const Dictionary &plan) {
        board = ready = false;
        w = plan.get("width", 0);
        h = plan.get("height", 0);
        if (w <= 0 || h <= 0 || w > 65536 || h > 65536 || w * h > INT32_MAX) return false;
        if (!read_ints(plan, "flags", flags) || static_cast<int64_t>(flags.size()) != w * h) return false;
        if (!read_ints(plan, "laser", laser) || static_cast<int64_t>(laser.size()) != w * h) return false;
        if (!sparse_ints(plan, "vehicle_cells", "vehicle_ids", vehicle, -1)) return false;
        beams.clear();
        board = true;
        return true;
    }

    // Occupants (AIPlanner.SO_* bits), the vehicle covering each cell (vehicle_covering:
    // footprints, and a piloted borg at its origin) with its durability, and the laser's
    // potential and costs (MCF.MARKSMAN_POTENTIAL and LASER_*).
    bool set_units(const Dictionary &plan) {
        units = false;
        if (!board) return false;
        if (!sparse_ints(plan, "occupant_cells", "occupant_bits", occupant, 0)) return false;
        if (!sparse_ints(plan, "cover_cells", "cover_ids", cover_vid, -1)) return false;
        if (!sparse_ints(plan, "cover_cells", "cover_durability", cover_dur, 0)) return false;
        std::vector<int32_t> k;
        if (!read_ints(plan, "laser_costs", k) || k.size() != 9 || k[1] <= 0 || k[7] <= 0) return false;
        k_potential = k[0]; k_per_durability = k[1]; k_kill = k[2]; k_kill_corpse = k[3]; k_shield = k[4];
        k_terrain_wall = k[5]; k_obscured = k[6]; k_glass_every = k[7]; k_glass_recharge = k[8];
        beams.clear();
        units = true;
        return true;
    }

    // ResolverWorld._seed_sight_activation as a full check (the incremental GDScript one
    // must equal it): for each sleeper (x, y), whether it sees a target (x, y: a soldier or a
    // hull cell) along a clear row, column or diagonal. los_blocked(sleeper, target,
    // allow_embrasure, units block, glass is clear, gas blocks); occupied lists the cells
    // holding a living unit. One byte per sleeper.
    PackedByteArray civilians_seeing(const PackedInt32Array &sleepers, const PackedInt32Array &targets,
            const PackedInt32Array &occupied) const {
        if (!board || sleepers.size() % 2 != 0 || targets.size() % 2 != 0) return PackedByteArray();
        std::vector<int32_t> t(targets.ptr(), targets.ptr() + targets.size());
        return sight_check(sleepers, t, occupied);
    }

    // The same check with the soldiers as ResolverWorld's wake-up rows: the (x, y) of every row
    // whose kind is 1 (_WA_TARGET), then the hull cells. No soldier: nobody sees (the hulls
    // alone wake no one), every byte 0.
    PackedByteArray civilians_seeing_rows(const PackedInt32Array &sleepers, const PackedInt32Array &xy,
            const PackedByteArray &kinds, const PackedInt32Array &hulls, const PackedInt32Array &occupied) const {
        if (!board || sleepers.size() % 2 != 0 || xy.size() != kinds.size() * 2 || hulls.size() % 2 != 0) {
            return PackedByteArray();
        }
        std::vector<int32_t> t;
        for (int64_t i = 0; i < kinds.size(); ++i) {
            if (kinds[i] != 1) continue;
            t.push_back(xy[i * 2]);
            t.push_back(xy[i * 2 + 1]);
        }
        if (t.empty()) {
            PackedByteArray none;
            none.resize(sleepers.size() / 2);
            none.fill(0);
            return none;
        }
        t.insert(t.end(), hulls.ptr(), hulls.ptr() + hulls.size());
        return sight_check(sleepers, t, occupied);
    }
    // AIController._best_smoke's firing lines and _smoke_value, after set_board(): "ours" and
    // "theirs" are [x, y, burst, marksman] per soldier in GDScript's order, with fire ranges;
    // a line is kept like GDScript keeps it (enemy -> our cell, clear of walls and gas,
    // someone can hit), and "through" lists, per cell, the lines crossing it in creation
    // order. Returns [the value of each landing (x, y pairs), the number of lines].
    Array smoke_values(const Dictionary &smoke) const {
        Array result;
        std::vector<int32_t> ours, theirs, landings;
        std::vector<double> ours_range, theirs_range, table;
        if (!board || !read_ints(smoke, "ours", ours) || !read_ints(smoke, "theirs", theirs)
                || !read_doubles(smoke, "ours_range", ours_range) || !read_doubles(smoke, "theirs_range", theirs_range)
                || !read_doubles(smoke, "hit_table", table) || !read_ints(smoke, "landings", landings)
                || ours.size() != ours_range.size() * 4 || theirs.size() != theirs_range.size() * 4
                || table.size() != 24 || landings.size() % 2 != 0) return result;
        const double marksman_hit = smoke.get("marksman_hit", 0.0), own_cost = smoke.get("own_cost", 0.0);
        const int64_t radius = smoke.get("radius", 0);
        // AIController._line_hit.
        auto line_hit = [&](const std::vector<int32_t> &who, const std::vector<double> &ranges, size_t k, int64_t d) {
            if (who[k * 4 + 3]) return marksman_hit;
            const int64_t need = hit_number(d, ranges[k]);
            if (need >= 7) return 0.0;
            return table[(need - 1) * 4 + who[k * 4 + 2] - 1];
        };
        for (size_t k = 0; k < theirs_range.size(); ++k) {
            if (!on_board(theirs[k * 4], theirs[k * 4 + 1]) || theirs[k * 4 + 2] < 1 || theirs[k * 4 + 2] > 4) return result;
        }
        for (size_t k = 0; k < ours_range.size(); ++k) {
            if (!on_board(ours[k * 4], ours[k * 4 + 1]) || ours[k * 4 + 2] < 1 || ours[k * 4 + 2] > 4) return result;
        }
        // Enemies by firing line: column, row and both diagonals.
        std::unordered_map<int64_t, std::vector<int32_t>> by_line;
        auto line_key = [](int64_t kind, int64_t value) { return kind * 4194304 + value + 2097152; };
        for (size_t k = 0; k < theirs_range.size(); ++k) {
            const int64_t x = theirs[k * 4], y = theirs[k * 4 + 1];
            for (const int64_t key : {line_key(0, x), line_key(1, y), line_key(2, x - y), line_key(3, x + y)}) {
                by_line[key].push_back(static_cast<int32_t>(k));
            }
        }
        std::vector<double> pe_of, pa_of;
        std::unordered_map<int64_t, std::vector<int32_t>> through;
        for (size_t a = 0; a < ours_range.size(); ++a) {
            const int64_t ax = ours[a * 4], ay = ours[a * 4 + 1];
            std::vector<int32_t> near;
            for (const int64_t key : {line_key(0, ax), line_key(1, ay), line_key(2, ax - ay), line_key(3, ax + ay)}) {
                auto found = by_line.find(key);
                if (found != by_line.end()) near.insert(near.end(), found->second.begin(), found->second.end());
            }
            std::sort(near.begin(), near.end());
            for (const int32_t e : near) {
                const int64_t ex = theirs[e * 4], ey = theirs[e * 4 + 1];
                if (!on_line(ex, ey, ax, ay)) continue;
                const int64_t d = std::max(std::abs(ex - ax), std::abs(ey - ay));
                if (line_blocked(ex, ey, ax, ay, true, true)) continue;
                const double pe = line_hit(theirs, theirs_range, e, d), pa = line_hit(ours, ours_range, a, d);
                if (pe <= 0.0 && pa <= 0.0) continue;
                const int32_t index = static_cast<int32_t>(pe_of.size());
                pe_of.push_back(pe);
                pa_of.push_back(pa);
                const int64_t sx = sign(ax - ex), sy = sign(ay - ey);
                for (int64_t x = ex, y = ey;; x += sx, y += sy) {
                    through[y * w + x].push_back(index);
                    if (x == ax && y == ay) break;
                }
            }
        }
        PackedFloat64Array values;
        values.resize(landings.size() / 2);
        std::vector<int64_t> seen(pe_of.size(), -1);
        std::vector<int32_t> order;
        for (size_t l = 0; l * 2 < landings.size(); ++l) {
            const int64_t lx = landings[l * 2], ly = landings[l * 2 + 1];
            order.clear();
            for (int64_t dy = -radius; dy <= radius; ++dy) {
                for (int64_t dx = -radius; dx <= radius; ++dx) {
                    if (!on_board(lx + dx, ly + dy)) continue;
                    auto found = through.find((ly + dy) * w + lx + dx);
                    if (found == through.end()) continue;
                    for (const int32_t i : found->second) {
                        if (seen[i] == static_cast<int64_t>(l)) continue;
                        seen[i] = static_cast<int64_t>(l);
                        order.push_back(i);
                    }
                }
            }
            double v = 0.0;
            for (const int32_t i : order) v += pe_of[i] - own_cost * pa_of[i];
            values.set(l, v);
        }
        result.push_back(values);
        result.push_back(static_cast<int64_t>(pe_of.size()));
        return result;
    }

    // The laser trace from a cell in a direction, flattened: [x, y, kind, cost, destroyed,
    // stop, damage, vehicle_id, left] per record. For parity tests against _laser_trace.
    PackedInt32Array beam(const Vector2i &from, const Vector2i &step) const {
        PackedInt32Array result;
        if (!units || !on_board(from.x, from.y) || std::abs(step.x) > 1 || std::abs(step.y) > 1) return result;
        for (const BeamRec &rec : beam_trace(from.x, from.y, step.x, step.y)) {
            for (const int64_t v : {rec.x, rec.y, rec.kind, rec.cost, static_cast<int64_t>(rec.destroyed),
                    static_cast<int64_t>(rec.stop), rec.damage, rec.vehicle, rec.left}) {
                result.push_back(static_cast<int32_t>(v));
            }
        }
        return result;
    }

    // AIPlanner._build_exposure's rays: threats are [x, y, marksman, burst] per enemy in
    // _threats order, ranges their fire ranges, hit_table[(need - 1) * 4 + burst - 1] the
    // chance of a hit, threat_seed the threat already on the cells (drones about to blow).
    Array exposure(const PackedInt32Array &threats, const PackedFloat64Array &ranges,
            const PackedFloat64Array &hit_table, bool p_classic, const PackedFloat64Array &threat_seed) const {
        Array result;
        if (!board || threats.size() != ranges.size() * 4 || hit_table.size() != 24 || threat_seed.size() != w * h) return result;
        PackedInt32Array seen;
        seen.resize(w * h);
        int32_t *counts = seen.ptrw();
        std::fill(counts, counts + w * h, 0);
        PackedFloat64Array risk = threat_seed;
        double *chance = risk.ptrw();
        for (int64_t t = 0; t < ranges.size(); ++t) {
            const int64_t tx = threats[t * 4], ty = threats[t * 4 + 1], burst = threats[t * 4 + 3];
            const bool marksman = threats[t * 4 + 2] != 0;
            const double range = ranges[t];
            if (!on_board(tx, ty) || burst < 1 || burst > 4) return Array();
            if (flags[ty * w + tx] & OBSCURED) continue;
            for (int dir = 0; dir < 8; ++dir) {
                int64_t x = tx + DX[dir], y = ty + DY[dir], d = 1;
                while (on_board(x, y)) {
                    if (!marksman && hit_number(d, range) >= 7) break;
                    const int64_t i = y * w + x;
                    const int32_t f = flags[i];
                    if (f & OBSCURED) break;
                    ++counts[i];
                    if (!p_classic) {
                        // AIPlanner._hit_chance.
                        double p = 0.0;
                        if (!((f & TRENCH) && d > 1)) {
                            int64_t need = marksman ? 3 : hit_number(d, range);
                            if (!marksman && d > 2) {
                                const int64_t sx = x - DX[dir], sy = y - DY[dir];
                                if (on_board(sx, sy)) need += (flags[sy * w + sx] >> SHIELD_SHIFT) & 7;
                            }
                            if (need < 7) p = hit_table[(need - 1) * 4 + burst - 1];
                        }
                        if (p > 0.0) chance[i] += p;
                    }
                    if (!marksman) {
                        if (f & WALL) {
                            if (!(d <= 1 && (f & (HEDGEHOG | DOT_OPEN)))) break;
                        } else if (vehicle[i] != -1) {
                            break;
                        }
                    }
                    x += DX[dir];
                    y += DY[dir];
                    ++d;
                }
            }
        }
        result.push_back(seen);
        result.push_back(risk);
        return result;
    }

    bool setup(const Dictionary &plan) {
        ready = false;
        if (!board || !units) return false;
        if (!read_ints(plan, "geo", geo) || static_cast<int64_t>(geo.size()) != w * h) return false;
        if (!read_ints(plan, "exposure", exposed) || static_cast<int64_t>(exposed.size()) != w * h) return false;
        if (!read_doubles(plan, "threat", threat) || static_cast<int64_t>(threat.size()) != w * h) return false;
        if (!sparse_doubles(plan, "veh_close_cells", "veh_close", veh_close)) return false;
        if (!sparse_ints(plan, "ally_cells", "ally_ids", ally, -1)) return false;
        std::vector<int32_t> marks;
        if (!sparse_ints(plan, "zone_cells", nullptr, marks, 0)) return false;
        zone.assign(marks.begin(), marks.end());
        if (!sparse_ints(plan, "tank_cells", nullptr, marks, 0)) return false;
        tank.assign(marks.begin(), marks.end());
        // Lanes: owners of each cell, CSR by cell.
        std::vector<int32_t> lane_cells, lane_counts, owners;
        if (!read_ints(plan, "lane_cells", lane_cells) || !read_ints(plan, "lane_counts", lane_counts)
                || !read_ints(plan, "lane_ids", owners) || lane_counts.size() != lane_cells.size()) return false;
        lane_start.assign(w * h + 1, 0);
        std::vector<std::vector<int32_t>> per_cell(lane_cells.size());
        int64_t total = 0;
        for (size_t i = 0; i < lane_cells.size(); ++i) {
            if (lane_cells[i] < 0 || lane_cells[i] >= w * h || lane_counts[i] < 0) return false;
            total += lane_counts[i];
        }
        if (total != static_cast<int64_t>(owners.size())) return false;
        std::vector<int32_t> count(w * h, 0), first(w * h, -1);
        for (size_t i = 0, k = 0; i < lane_cells.size(); ++i) {
            if (first[lane_cells[i]] != -1) return false;
            first[lane_cells[i]] = static_cast<int32_t>(k);
            count[lane_cells[i]] = lane_counts[i];
            k += lane_counts[i];
        }
        lane_ids.clear();
        lane_ids.reserve(owners.size());
        for (int64_t c = 0; c < w * h; ++c) {
            lane_start[c] = static_cast<int32_t>(lane_ids.size());
            for (int32_t k = 0; k < count[c]; ++k) lane_ids.push_back(owners[first[c] + k]);
        }
        lane_start[w * h] = static_cast<int32_t>(lane_ids.size());
        // Enemies in AIPlanner._enemies order; enemy vehicles in _veh_targets order.
        std::vector<int32_t> xy;
        if (!read_ints(plan, "enemy_xy", xy) || xy.size() % 2 != 0) return false;
        if (!read_doubles(plan, "enemy_values", evalue) || evalue.size() * 2 != xy.size()) return false;
        ex.clear();
        ey.clear();
        for (size_t i = 0; i < xy.size(); i += 2) {
            if (!on_board(xy[i], xy[i + 1])) return false;
            ex.push_back(xy[i]);
            ey.push_back(xy[i + 1]);
        }
        std::vector<int32_t> fxy, fcount;
        if (!read_ints(plan, "veh_xy", fxy) || !read_ints(plan, "veh_counts", fcount) || fxy.size() % 2 != 0) return false;
        if (!read_ints(plan, "veh_ids", vids) || vids.size() != fcount.size()) return false;
        vx.clear();
        vy.clear();
        vstart.assign(1, 0);
        int64_t used = 0;
        for (const int32_t n : fcount) {
            if (n < 0) return false;
            used += n;
            vstart.push_back(static_cast<int32_t>(used));
        }
        if (used * 2 != static_cast<int64_t>(fxy.size())) return false;
        for (size_t i = 0; i < fxy.size(); i += 2) {
            vx.push_back(fxy[i]);
            vy.push_back(fxy[i + 1]);
        }
        std::vector<double> weights;
        if (!read_doubles(plan, "weights", weights) || weights.size() != 17) return false;
        w_fire = weights[0]; w_ease = weights[1]; w_adv = weights[2]; w_cover = weights[3];
        w_trench = weights[4]; w_danger = weights[5]; w_threat = weights[6]; w_shelter = weights[7];
        w_obj = weights[8]; w_zone = weights[9]; w_step = weights[10]; obj_share = weights[11];
        w_spread = weights[12]; w_lane_block = weights[13]; w_lane_clear = weights[14];
        w_tank_path = weights[15]; w_veh_fire = weights[16];
        classic = plan.get("classic", true);
        spread = plan.get("spread", false);
        at_min_range = plan.get("at_min_range", 0);
        smoke_penalty = plan.get("smoke_penalty", 0);
        geo_far = plan.get("geo_far", 0);
        ready = true;
        return true;
    }

    // Enemies (indices, ascending) that some of these cells could fire on, all but futility
    // checked: GDScript answers shot_is_futile for exactly these.
    PackedInt32Array targets(double range, bool fireproof, bool marksman, const PackedInt32Array &cells) const {
        PackedInt32Array result;
        if (!ready || !cells_ok(cells)) return result;
        std::vector<uint8_t> wanted(ex.size(), 0);
        for (int64_t i = 0; i < cells.size(); ++i) {
            const int64_t x = cells[i] % w, y = cells[i] / w;
            if (!fireproof && (fire_near(x, y) || (!classic && fire_creeps(x, y)))) continue;
            for (size_t e = 0; e < ex.size(); ++e) {
                if (wanted[e] || !on_line(x, y, ex[e], ey[e])) continue;
                if ((marksman ? ease_marksman(x, y, e, range, nullptr) : ease(x, y, e, range, nullptr)) == -2.0) wanted[e] = 1;
            }
        }
        for (size_t e = 0; e < wanted.size(); ++e) {
            if (wanted[e]) result.push_back(static_cast<int32_t>(e));
        }
        return result;
    }

    // soldier: [id, range, fireproof, ability, start_geo, start_obj, leaving_lane, objective field,
    // marksman]: ability is attack_ability() (0 other, ABILITY_*), marksman the shooter's stats.
    PackedFloat64Array score(const Array &soldier, const PackedInt32Array &cells, const PackedInt32Array &steps,
            const PackedByteArray &futile) const {
        PackedFloat64Array result;
        if (!ready || soldier.size() != 9 || cells.size() != steps.size() || !cells_ok(cells)
                || futile.size() != static_cast<int64_t>(ex.size())) return result;
        const int64_t uid = soldier[0];
        const double range = soldier[1];
        const bool fireproof = soldier[2];
        const int64_t ability = soldier[3], start_geo = soldier[4], start_obj = soldier[5];
        const bool leaving_lane = soldier[6];
        if (soldier[7].get_type() != Variant::PACKED_INT32_ARRAY) return result;
        const PackedInt32Array objective = soldier[7];
        const bool marksman = soldier[8];
        const bool has_obj = !objective.is_empty();
        if (has_obj && objective.size() != w * h) return result;
        const uint8_t *no_shot = futile.ptr();
        result.resize(cells.size());
        double *out = result.ptrw();
        for (int64_t i = 0; i < cells.size(); ++i) {
            const int64_t c = cells[i], x = c % w, y = c / w;
            if (!fireproof && (fire_near(x, y) || (!classic && fire_creeps(x, y)))) {
                out[i] = -1e9;
                continue;
            }
            double score = 0.0;
            for (size_t e = 0; e < ex.size(); ++e) {
                if (!on_line(x, y, ex[e], ey[e])) continue;
                const double e_ease = marksman ? ease_marksman(x, y, e, range, no_shot) : ease(x, y, e, range, no_shot);
                if (e_ease < 0.0) continue;
                score += w_fire + e_ease * w_ease + evalue[e];
            }
            if (has_obj) {
                const int64_t og = objective[c];
                if (start_obj < geo_far && og < geo_far) score += static_cast<double>(start_obj - og) * w_obj;
            }
            if (zone[c]) score += w_zone;
            const int64_t g = geo[c];
            const double adv = w_adv * (has_obj ? obj_share : 1.0);
            if (start_geo < geo_far && g < geo_far) score += static_cast<double>(start_geo - g) * adv;
            else if (g < geo_far) score += adv;
            const int32_t f = flags[c];
            if (classic) {
                if (f & COVER) score += static_cast<double>((f >> COVER_SHIFT) & 7) * w_cover;
                if (f & TRENCH) score += w_cover * w_trench;
                score += static_cast<double>(exposed[c]) * w_danger;
            } else {
                score += threat[c] * w_threat;
                if (ability != ABILITY_MINER) score += veh_close[c] * w_threat;
                if (ability == ABILITY_AT || ability == ABILITY_MARKSMAN) score += vehicle_fire_value(x, y, range, ability);
                score += shelter(x, y) * w_shelter;
                if (spread) {
                    int64_t near = 0;
                    for (int k = 0; k < 8; ++k) {
                        const int64_t nx = x + DX[k], ny = y + DY[k];
                        if (on_board(nx, ny) && ally[ny * w + nx] != -1 && ally[ny * w + nx] != uid) ++near;
                    }
                    score += static_cast<double>(near) * w_spread;
                }
                if (f & TRENCH) score += w_cover * w_trench;
            }
            int64_t lanes = lane_start[c + 1] - lane_start[c];
            for (int32_t k = lane_start[c]; k < lane_start[c + 1]; ++k) {
                if (lane_ids[k] == uid) { --lanes; break; }
            }
            if (lanes > 0) score += static_cast<double>(lanes) * w_lane_block;
            else if (leaving_lane) score += w_lane_clear;
            if (tank[c]) score += w_tank_path;
            score += static_cast<double>(steps[i]) * w_step;
            out[i] = score;
        }
        return result;
    }
};

void register_ai_kernel() {
    ClassDB::register_class<MCFAI>();
    ClassDB::register_class<MCFPlanScorer>();
}
