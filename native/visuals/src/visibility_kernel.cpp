#include "visibility_kernel.h"
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <vector>

using namespace godot;

// Integer octant intervals are identical to ResolverVision's reference sweep.
// The object is stateless: several visibility workers may call it concurrently.
class MCFVisibility : public RefCounted {
    GDCLASS(MCFVisibility, RefCounted);
    struct Interval { int64_t ln, ld, hn, hd; };
    static int64_t fdiv(int64_t p, int64_t q) {
        return p / q - ((p % q) < 0 ? 1 : 0);
    }
    static bool valid(const PackedByteArray &mask, int64_t w, int64_t h) {
        return w > 0 && h > 0 && w <= INT32_MAX && h <= INT32_MAX &&
            w * h <= INT32_MAX && mask.size() == w * h;
    }
    static void progression(std::vector<int32_t> &out, int64_t start, int64_t step, int64_t count) {
        for (int64_t i = 0; i < count; ++i) out.push_back(static_cast<int32_t>(start + i * step));
    }
    static PackedInt32Array packed(const std::vector<int32_t> &values) {
        PackedInt32Array out;
        out.resize(values.size());
        if (!values.empty()) std::copy(values.begin(), values.end(), out.ptrw());
        return out;
    }
    static void close_interval(std::vector<Interval> &ranges, int64_t a, int64_t j) {
        Interval next{2 * j - 1, 2 * a, 2 * j + 1, 2 * a};
        size_t p = 0;
        while (p < ranges.size() && ranges[p].hn * next.ld < next.ln * ranges[p].hd) ++p;
        size_t q = p;
        while (q < ranges.size() && ranges[q].ln * next.hd <= next.hn * ranges[q].ld) {
            if (ranges[q].ln * next.ld < next.ln * ranges[q].ld) {
                next.ln = ranges[q].ln; next.ld = ranges[q].ld;
            }
            if (ranges[q].hn * next.hd > next.hn * ranges[q].hd) {
                next.hn = ranges[q].hn; next.hd = ranges[q].hd;
            }
            ++q;
        }
        if (p == q) ranges.insert(ranges.begin() + p, next);
        else {
            ranges[p] = next;
            ranges.erase(ranges.begin() + p + 1, ranges.begin() + q);
        }
    }
    Array walk(int64_t ux, int64_t uy, int64_t radius, const PackedByteArray &mask,
               int64_t w, int64_t h, PackedByteArray transposed, bool hidden,
               const PackedInt32Array &blockers) const {
        Array result;
        if (!valid(mask, w, h) || ux < 0 || uy < 0 || ux >= w || uy >= h) return result;
        if (transposed.is_empty()) transposed = transpose(mask, w, h);
        if (transposed.size() != mask.size()) return result;
        const int64_t origin = uy * w + ux;
        std::vector<int32_t> out, sensitive;
        if (!hidden) out.push_back(static_cast<int32_t>(origin));
        std::array<int64_t, 8> first;
        first.fill(hidden ? INT32_MAX : 1);
        if (hidden) {
            for (int64_t i = 0; i < blockers.size(); ++i) {
                const int64_t g = blockers[i];
                if (g < 0 || g >= w * h) return result;
                const int64_t dx = g % w - ux, dy = g / w - uy;
                for (int oct = 0; oct < 8; ++oct) {
                    const int64_t sx = (oct & 1) ? -1 : 1, sy = (oct & 2) ? -1 : 1;
                    const int64_t a = oct < 4 ? dx * sx : dy * sy;
                    const int64_t j = oct < 4 ? dy * sy : dx * sx;
                    if (a >= 1 && j >= 0 && j <= a && a < first[oct]) first[oct] = a;
                }
            }
        }
        for (int oct = 0; oct < 8; ++oct) {
            const bool xmajor = oct < 4;
            const int64_t sx = (oct & 1) ? -1 : 1, sy = (oct & 2) ? -1 : 1;
            const int64_t major_step = xmajor ? sx : sy * w;
            const int64_t minor_step = xmajor ? sy * w : sx;
            const int64_t major_room = xmajor ? (sx > 0 ? w - 1 - ux : ux) : (sy > 0 ? h - 1 - uy : uy);
            const int64_t minor_room = xmajor ? (sy > 0 ? h - 1 - uy : uy) : (sx > 0 ? w - 1 - ux : ux);
            const uint8_t *run = xmajor ? transposed.ptr() : mask.ptr();
            const int64_t run_dir = xmajor ? sy : sx;
            const int64_t b0 = (xmajor ? sy < 0 : sx < 0) ? 1 : 0;
            const int64_t amax = hidden ? major_room : std::min(radius, major_room);
            std::vector<Interval> ranges;
            bool closed = false;
            for (int64_t a = first[oct]; a <= amax; ++a) {
                const int64_t col = origin + major_step * a;
                const int64_t bmax = std::min(xmajor ? a : a - 1, minor_room);
                if (closed) {
                    if (bmax >= b0) progression(out, col + minor_step * b0, minor_step, bmax - b0 + 1);
                    continue;
                }
                const int64_t jmax = std::min(a, minor_room);
                int64_t cur = b0;
                for (size_t k = 0; k < ranges.size() && cur <= bmax; ++k) {
                    const Interval &s = ranges[k];
                    const int64_t bs = fdiv(a * s.ln, s.ld) + 1;
                    if (bs > bmax) break;
                    const int64_t be = fdiv(a * s.hn, s.hd);
                    if (be >= cur && bs <= be) {
                        if (hidden) {
                            const int64_t hs = std::max(bs, cur), he = std::min(be, bmax);
                            if (he >= hs) progression(out, col + minor_step * hs, minor_step, he - hs + 1);
                        } else if (bs > cur) progression(out, col + minor_step * cur, minor_step, bs - cur);
                        cur = be + 1;
                    }
                }
                if (!hidden) {
                    if (cur <= bmax) progression(out, col + minor_step * cur, minor_step, bmax - cur + 1);
                    int64_t js = 0;
                    for (size_t k = 0; k < ranges.size() && js <= jmax; ++k) {
                        const Interval &s = ranges[k];
                        const int64_t cs = -fdiv(-(2 * a * s.ln + s.ld), 2 * s.ld);
                        if (cs > jmax) break;
                        const int64_t ce = fdiv(2 * a * s.hn - s.hd, 2 * s.hd);
                        if (ce >= js && cs <= ce) {
                            if (cs > js) progression(sensitive, col + minor_step * js, minor_step, cs - js);
                            js = ce + 1;
                        }
                    }
                    if (js <= jmax) progression(sensitive, col + minor_step * js, minor_step, jmax - js + 1);
                }
                const int64_t base = xmajor ? (ux + sx * a) * h + uy : col;
                const int64_t from = run_dir > 0 ? base : base - jmax;
                // Scan in exactly the same order as PackedByteArray.find on the slice.
                for (int64_t hit = 0; hit <= jmax; ++hit) {
                    if (run[from + hit] == 1) close_interval(ranges, a, run_dir > 0 ? hit : jmax - hit);
                }
                if (ranges.size() == 1 && ranges[0].ln < 0 && ranges[0].hn >= ranges[0].hd) {
                    if (hidden) closed = true;
                    else break;
                }
            }
        }
        if (!hidden) {
            std::sort(out.begin(), out.end());
            std::sort(sensitive.begin(), sensitive.end());
            sensitive.erase(std::unique(sensitive.begin(), sensitive.end()), sensitive.end());
        }
        result.push_back(packed(out));
        result.push_back(packed(sensitive));
        return result;
    }
protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("api_version"), &MCFVisibility::api_version);
        ClassDB::bind_method(D_METHOD("sweep", "x", "y", "radius", "mask", "width", "height", "transposed"), &MCFVisibility::sweep);
        ClassDB::bind_method(D_METHOD("hidden", "x", "y", "mask", "width", "height", "transposed", "blockers"), &MCFVisibility::hidden);
        ClassDB::bind_method(D_METHOD("transpose", "mask", "width", "height"), &MCFVisibility::transpose);
        ClassDB::bind_method(D_METHOD("merge_visibility", "cells", "counts", "visible", "explored", "width", "log", "add"), &MCFVisibility::merge_visibility);
    }
public:
    int64_t api_version() const { return 1; }
    Array sweep(int64_t x, int64_t y, int64_t radius, const PackedByteArray &mask,
                int64_t w, int64_t h, const PackedByteArray &transposed) const {
        return walk(x, y, radius, mask, w, h, transposed, false, PackedInt32Array());
    }
    PackedInt32Array hidden(int64_t x, int64_t y, const PackedByteArray &mask,
                           int64_t w, int64_t h, const PackedByteArray &transposed,
                           const PackedInt32Array &blockers) const {
        const Array result = walk(x, y, 0, mask, w, h, transposed, true, blockers);
        return result.is_empty() ? PackedInt32Array() : PackedInt32Array(result[0]);
    }
    PackedByteArray transpose(const PackedByteArray &mask, int64_t w, int64_t h) const {
        PackedByteArray out;
        if (!valid(mask, w, h)) return out;
        out.resize(mask.size());
        uint8_t *dst = out.ptrw();
        const uint8_t *src = mask.ptr();
        for (int64_t y = 0; y < h; ++y)
            for (int64_t x = 0; x < w; ++x) dst[x * h + y] = src[y * w + x] != 0 ? 1 : 0;
        return out;
    }
    PackedInt32Array merge_visibility(const PackedInt32Array &cells, PackedInt32Array counts,
                                     Dictionary visible, Dictionary explored, int64_t width,
                                     const Variant &log, bool add) const {
        if (width <= 0 || (log.get_type() != Variant::NIL && log.get_type() != Variant::ARRAY)) return counts;
        for (int64_t i = 0; i < cells.size(); ++i)
            if (cells[i] < 0 || cells[i] >= counts.size()) return counts;
        const bool record = log.get_type() == Variant::ARRAY;
        Array changes = record ? Array(log) : Array();
        int32_t *data = counts.ptrw();
        for (int64_t k = 0; k < cells.size(); ++k) {
            const int64_t i = cells[k];
            const int32_t before = data[i];
            data[i] = static_cast<int32_t>(static_cast<int64_t>(before) + (add ? 1 : -1));
            if ((add && before == 0) || (!add && data[i] == 0)) {
                const Vector2i coord(i % width, i / width);
                if (add) { visible[coord] = true; explored[coord] = true; }
                else visible.erase(coord);
                if (record) changes.push_back(i);
            }
        }
        return counts;
    }
};

void register_visibility_kernel() { ClassDB::register_class<MCFVisibility>(); }
