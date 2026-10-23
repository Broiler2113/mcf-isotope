#include "terrain_kernel.h"

#include <godot_cpp/classes/geometry2d.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

using namespace godot;

// Terrain decisions and dense preparation only. Resource loading, staged jobs and
// scene ownership remain in Godot; no game-state property is ever modified here.
class MCFTerrain : public RefCounted {
    GDCLASS(MCFTerrain, RefCounted);

    static bool valid_grid(const Array &cells, int64_t width, int64_t height) {
        return width > 0 && height > 0 && width <= 100000 && height <= 100000 &&
            width * height <= cells.size();
    }

    static uint32_t variant_hash(const Vector2i &cell) {
        const int64_t hash = (int64_t(cell.x) * 73856093) ^ (int64_t(cell.y) * 19349663);
        // GDScript wraps integer multiplication; unsigned multiplication avoids
        // signed-overflow UB while retaining the same masked low 31 bits.
        return uint32_t((uint64_t(hash ^ (hash >> 13)) * uint64_t(1274126177)) & 0x7fffffff);
    }

protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("api_version"), &MCFTerrain::api_version);
        ClassDB::bind_method(D_METHOD("roofed", "cells", "width", "height", "looks", "indoor", "rules"), &MCFTerrain::roofed);
        ClassDB::bind_method(D_METHOD("floor_plan", "cells", "width", "height", "looks", "damage", "rect", "origin", "settings"), &MCFTerrain::floor_plan);
        ClassDB::bind_method(D_METHOD("paint_floor", "image", "plan", "tiles", "first", "count", "resolution"), &MCFTerrain::paint_floor);
        ClassDB::bind_method(D_METHOD("paint_ground_lines", "image", "lines", "origin", "resolution"), &MCFTerrain::paint_ground_lines);
    }

public:
    int64_t api_version() const { return 1; }

    PackedByteArray roofed(const Array &cells, int64_t width, int64_t height,
                          const PackedByteArray &looks, bool indoor, const Dictionary &rules) const {
        if (!valid_grid(cells, width, height)) return {};
        const int64_t total = width * height;
        std::vector<uint8_t> barrier(total), space(total), seed(total), outside(total);
        const StringName space_key("is_space"), feature_key("feature_id"), cover_key("cover_height"), floor_key("floor_type");
        const String boundary = rules["boundary"], airlock = rules["airlock"];
        const Array glass = rules["glass"];
        const double wall_height = rules["wall_height"];
        const int64_t grass_type = rules["grass_type"], grass_look = rules["grass_look"], dirt_look = rules["dirt_look"];
        PackedByteArray result;
        result.resize(total);
        uint8_t *out = result.ptrw();
        for (int64_t i = 0; i < total; ++i) {
            Object *cell = cells[i];
            if (!cell) return {};
            space[i] = bool(cell->get(space_key));
            if (indoor) { out[i] = space[i] ? 0 : 1; continue; }
            const String feature = cell->get(feature_key);
            barrier[i] = feature != boundary && (double(cell->get(cover_key)) >= wall_height || feature == airlock || glass.has(feature));
            const int64_t look = i < looks.size() ? looks[i] : 0;
            const int64_t x = i % width, y = i / width;
            seed[i] = !barrier[i] && (x == 0 || y == 0 || x == width - 1 || y == height - 1 || space[i] ||
                int64_t(cell->get(floor_key)) == grass_type || look == grass_look || look == dirt_look);
        }
        if (indoor) return result;
        std::vector<int64_t> queue;
        queue.reserve(total);
        for (int64_t i = 0; i < total; ++i) if (seed[i]) { outside[i] = 1; queue.push_back(i); }
        const int dx[] = {1, -1, 0, 0}, dy[] = {0, 0, 1, -1};
        for (size_t head = 0; head < queue.size(); ++head) {
            const int64_t i = queue[head], x = i % width, y = i / width;
            for (int d = 0; d < 4; ++d) {
                const int64_t nx = x + dx[d], ny = y + dy[d];
                if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
                const int64_t j = ny * width + nx;
                if (!outside[j] && !barrier[j]) { outside[j] = 1; queue.push_back(j); }
            }
        }
        for (int64_t i = 0; i < total; ++i) out[i] = !outside[i] && !space[i] && !barrier[i] ? 1 : 0;
        for (int64_t y = 0; y < height; ++y) for (int64_t x = 0; x < width; ++x) {
            const int64_t i = y * width + x;
            if (out[i] || !barrier[i]) continue;
            for (int oy = -1; oy <= 1; ++oy) for (int ox = -1; ox <= 1; ++ox) {
                const int64_t nx = x + ox, ny = y + oy;
                if ((ox == 0 && oy == 0) || nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
                const int64_t j = ny * width + nx;
                if (out[j] == 1 && !barrier[j]) out[i] = 2;
            }
        }
        for (int64_t i = 0; i < total; ++i) if (out[i] == 2) out[i] = 1;
        return result;
    }

    Dictionary floor_plan(const Array &cells, int64_t width, int64_t height,
            const PackedByteArray &looks, const Dictionary &damage, const Rect2i &rect,
            const Vector2i &origin, const Dictionary &settings) const {
        if (!valid_grid(cells, width, height) || rect.position.x < 0 || rect.position.y < 0 ||
                rect.size.x < 1 || rect.size.y < 1 || int64_t(rect.position.x) + rect.size.x > width ||
                int64_t(rect.position.y) + rect.size.y > height) return {};
        const StringName space_key("is_space"), feature_key("feature_id"), floor_key("floor_type");
        const Array floor_names = settings["floor_names"];
        const Dictionary overlays = settings["overlays"], ground_names = settings["ground_names"], winter_names = settings["winter_names"];
        const String env = settings["env"], airlock = settings["airlock"];
        const bool outdoor = env == "town" || env == "field" || env == "asteroid";
        const bool space_override = settings["space_override"];
        const int64_t solar = settings["solar"], grass = settings["grass_look"], dirt = settings["dirt_look"];
        const int64_t grass_type = settings["grass_type"], epicenter = settings["epicenter"], rubble = settings["rubble"];
        const int64_t count = int64_t(rect.size.x) * rect.size.y;
        PackedStringArray names;
        PackedInt32Array hashes;
        names.resize(count * 2);
        hashes.resize(count);
        Dictionary needed;
        for (int64_t row = 0; row < rect.size.y; ++row) for (int64_t col = 0; col < rect.size.x; ++col) {
            const Vector2i at = rect.position + Vector2i(col, row);
            const int64_t i = int64_t(at.y) * width + at.x, local = row * rect.size.x + col;
            Object *cell = cells[i];
            if (!cell) return {};
            const bool space = cell->get(space_key);
            const int64_t look = i < looks.size() ? looks[i] : 0;
            const int64_t damaged = damage.get(at, 0);
            String floor;
            if (space) floor = look == solar ? String("floor_solar") : (space_override ? String("floor_space") : String());
            else if (damaged == epicenter) floor = "floor_epicenter";
            else if (damaged == rubble) floor = "floor_destroyed";
            else {
                const bool door = outdoor && String(cell->get(feature_key)) == airlock;
                if (door && (look == 0 || look == dirt || look == grass || look >= floor_names.size())) floor = "floor_plate";
                else if (door && !overlays.has(look)) floor = floor_names[look];
                else if (int64_t(cell->get(floor_key)) == grass_type) floor = "floor_grass";
                else if (look > 0 && look < floor_names.size() && look != solar && !overlays.has(look)) floor = floor_names[look];
                else floor = "floor";
            }
            const String ground = ground_names.get(floor, floor);
            if (!space && (ground == "floor_grass" || ground == "floor_field")) floor = "";
            floor = winter_names.get(floor, floor);
            String overlay;
            if (overlays.has(look) && (space || damaged == 0) && look < floor_names.size()) overlay = floor_names[look];
            names[local * 2] = floor;
            names[local * 2 + 1] = overlay;
            hashes[local] = variant_hash(at + origin);
            if (!floor.is_empty()) needed[floor] = true;
            if (!overlay.is_empty()) needed[overlay] = true;
        }
        Dictionary result;
        result["size"] = rect.size;
        result["names"] = names;
        result["hashes"] = hashes;
        result["needed"] = needed;
        return result;
    }

    bool paint_floor(const Ref<Image> &image, const Dictionary &plan, const Dictionary &tiles,
                     int64_t first, int64_t count, int64_t resolution) const {
        if (image.is_null() || !plan.has("size") || !plan.has("names") || !plan.has("hashes") || resolution < 1 ||
            resolution > image->get_width() || resolution > image->get_height()) return false;
        const Vector2i size = plan["size"];
        const PackedStringArray names = plan["names"];
        const PackedInt32Array hashes = plan["hashes"];
        const int64_t total = int64_t(size.x) * size.y;
        if (size.x < 1 || size.y < 1 || names.size() != total * 2 || hashes.size() != total ||
            first < 0 || count < 0 || first > total || count > total - first ||
            image->get_width() != size.x * resolution || image->get_height() != size.y * resolution) return false;
        for (int64_t i = first; i < first + count; ++i) {
            if (hashes[i] < 0) return false;
            for (int layer = 0; layer < 2; ++layer) {
                const String name = names[i * 2 + layer];
                const Array variants = tiles.get(name, Array());
                if (!variants.is_empty()) {
                    const Ref<Image> tile = variants[hashes[i] % variants.size()];
                    if (tile.is_null()) return false;
                }
            }
        }
        const Rect2i source(0, 0, resolution, resolution);
        for (int64_t i = first; i < first + count; ++i) {
            const Vector2i at((i % size.x) * resolution, (i / size.x) * resolution);
            for (int layer = 0; layer < 2; ++layer) {
                const String name = names[i * 2 + layer];
                if (name.is_empty()) continue;
                const Array variants = tiles.get(name, Array());
                if (variants.is_empty()) {
                    if (layer == 0) image->fill_rect(Rect2i(at, Vector2i(resolution, resolution)), Color(0.14, 0.15, 0.18));
                } else {
                    const Ref<Image> tile = variants[hashes[i] % variants.size()];
                    if (layer == 0) image->blit_rect(tile, source, at);
                    else image->blend_rect(tile, source, at);
                }
            }
        }
        return true;
    }

    bool paint_ground_lines(const Ref<Image> &image, const Array &lines, const Vector2 &origin, int64_t resolution) const {
        if (image.is_null() || resolution < 1 || resolution > 65536 || !origin.is_finite()) return false;
        // Validate before touching the supplied image, so the caller may fall back.
        for (int64_t i = 0; i < lines.size(); ++i) {
            if (lines[i].get_type() != Variant::ARRAY) return false;
            const Array line = lines[i];
            if (line.size() < 3 || line[0].get_type() != Variant::VECTOR2 || line[1].get_type() != Variant::VECTOR2) return false;
            if (!Vector2(line[0]).is_finite() || !Vector2(line[1]).is_finite()) return false;
        }
        Geometry2D *geometry = Geometry2D::get_singleton();
        for (int64_t i = 0; i < lines.size(); ++i) {
            const Array line = lines[i];
            const Vector2 a = (Vector2(line[0]) - origin) * resolution;
            const Vector2 b = (Vector2(line[1]) - origin) * resolution;
            const bool track = int64_t(line[2]) == 0;
            const double radius = std::max(0.5, resolution * (track ? 0.11 : 0.04));
            const Color ink = track ? Color(0.1, 0.08, 0.05, 0.2) : Color(0, 0, 0, 0.4);
            const Vector2 lo = a.min(b) - Vector2(1, 1) * radius;
            const Vector2 hi = a.max(b) + Vector2(1, 1) * radius;
            const double dy = double(b.y) - double(a.y);
            const int y0 = int(std::clamp(std::floor(double(lo.y)), 0.0, double(image->get_height())));
            const int y1 = int(std::clamp(std::ceil(double(hi.y)), 0.0, double(image->get_height())));
            for (int y = y0; y < y1; ++y) {
                double left = lo.x, right = hi.x;
                if (std::abs(dy) > 0.00001) {
                    const double x0 = Math::lerp(double(a.x), double(b.x), std::clamp((y + 0.5 - radius - a.y) / dy, 0.0, 1.0));
                    const double x1 = Math::lerp(double(a.x), double(b.x), std::clamp((y + 0.5 + radius - a.y) / dy, 0.0, 1.0));
                    left = std::max(left, std::min(x0, x1) - radius);
                    right = std::min(right, std::max(x0, x1) + radius);
                }
                const int x0 = int(std::clamp(std::floor(left), 0.0, double(image->get_width())));
                const int x1 = int(std::clamp(std::ceil(right), 0.0, double(image->get_width())));
                for (int x = x0; x < x1; ++x) {
                    const Vector2 p(x + 0.5, y + 0.5);
                    if (p.distance_to(geometry->get_closest_point_to_segment(p, a, b)) <= radius)
                        image->set_pixel(x, y, image->get_pixel(x, y).blend(ink));
                }
            }
        }
        return true;
    }
};

void register_terrain_kernel() { ClassDB::register_class<MCFTerrain>(); }
