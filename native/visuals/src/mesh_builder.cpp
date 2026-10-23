#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <algorithm>
#include <vector>
#include "visibility_kernel.h"
#include "pathfinding_kernel.h"
#include "ai_kernel.h"
#include "terrain_kernel.h"

using namespace godot;

// The scene and model descriptions stay in GDScript. This owns only the dense
// vertex buffers, with the same triangulation, UVs and color arithmetic as Sink.
class MCFMeshBuilder : public RefCounted {
    GDCLASS(MCFMeshBuilder, RefCounted)
    std::vector<Vector3> positions, normals;
    std::vector<Vector2> uvs, layers;
    std::vector<Color> colors;
    Array cached;

    void vertex(const Vector3 &p, const Vector3 &n, const Vector2 &uv,
                const Vector2 &layer, Color color, bool shade) {
        positions.push_back(p);
        normals.push_back(n);
        uvs.push_back(uv);
        layers.push_back(layer);
        if (shade && color.a > 0.5) {
            const double k = 0.62 + 0.38 * Math::smoothstep(0.0, 0.32, static_cast<double>(p.y));
            color = Color(color.r * k, color.g * k, color.b * k, color.a);
        }
        colors.push_back(color);
    }

    void polygon(const std::vector<Vector3> &points, const Vector3 &out,
                 const std::vector<Vector2> *explicit_uvs, int64_t material,
                 const Color &color, const Transform3D &transform, bool shade) {
        cached.clear();
        const Vector3 normal = transform.basis.xform(out).normalized();
        const Vector3 an = normal.abs();
        std::vector<Vector3> world;
        std::vector<Vector2> coords;
        world.reserve(points.size());
        coords.reserve(points.size());
        for (size_t i = 0; i < points.size(); ++i) {
            const Vector3 p = transform.xform(points[i]);
            world.push_back(p);
            if (explicit_uvs) coords.push_back((*explicit_uvs)[i]);
            else if (an.y >= an.x && an.y >= an.z) coords.emplace_back(p.x, p.z);
            else if (an.x >= an.z) coords.emplace_back(p.z, -p.y);
            else coords.emplace_back(p.x, -p.y);
        }
        const Vector2 layer(material, 0);
        for (size_t t = 1; t + 1 < world.size(); ++t) {
            const bool reverse = (world[t] - world[0]).cross(world[t + 1] - world[0]).dot(normal) > 0.0;
            const size_t second = reverse ? t + 1 : t;
            const size_t third = reverse ? t : t + 1;
            vertex(world[0], normal, coords[0], layer, color, shade);
            vertex(world[second], normal, coords[second], layer, color, shade);
            vertex(world[third], normal, coords[third], layer, color, shade);
        }
    }

    static bool read_points(const Array &input, std::vector<Vector3> &output) {
        // All production faces are small. Reject malformed calls before modifying buffers.
        if (input.size() > 65536) return false;
        output.reserve(input.size());
        for (int64_t i = 0; i < input.size(); ++i) {
            if (input[i].get_type() != Variant::VECTOR3) return false;
            output.push_back(input[i]);
        }
        return true;
    }

    template<typename Packed, typename T>
    static Packed packed(const std::vector<T> &values) {
        Packed out;
        out.resize(values.size());
        if (!values.empty()) std::copy(values.begin(), values.end(), out.ptrw());
        return out;
    }

protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("api_version"), &MCFMeshBuilder::api_version);
        ClassDB::bind_method(D_METHOD("face", "points", "normal", "material", "color", "transform", "shade"), &MCFMeshBuilder::face);
        ClassDB::bind_method(D_METHOD("face_uv", "points", "normal", "uvs", "color", "transform", "shade"), &MCFMeshBuilder::face_uv);
        ClassDB::bind_method(D_METHOD("box", "lo", "hi", "material", "color", "skip", "transform", "shade"), &MCFMeshBuilder::box);
        ClassDB::bind_method(D_METHOD("add_vertex", "position", "normal", "uv", "layer", "color", "shade"), &MCFMeshBuilder::add_vertex);
        ClassDB::bind_method(D_METHOD("arrays"), &MCFMeshBuilder::arrays);
        ClassDB::bind_method(D_METHOD("empty"), &MCFMeshBuilder::empty);
    }
public:
    int64_t api_version() const { return 1; }
    bool empty() const { return positions.empty(); }

    bool face(const Array &input, const Vector3 &out, int64_t material, const Color &color,
              const Transform3D &transform, bool shade) {
        std::vector<Vector3> points;
        if (!read_points(input, points)) return false;
        polygon(points, out, nullptr, material, color, transform, shade);
        return true;
    }

    bool face_uv(const Array &input, const Vector3 &out, const Array &input_uvs,
                 const Color &color, const Transform3D &transform, bool shade) {
        std::vector<Vector3> points;
        if (!read_points(input, points) || input_uvs.size() < input.size()) return false;
        std::vector<Vector2> coords;
        coords.reserve(points.size());
        for (int64_t i = 0; i < input.size(); ++i) {
            if (input_uvs[i].get_type() != Variant::VECTOR2) return false;
            coords.push_back(input_uvs[i]);
        }
        polygon(points, out, &coords, 0, color, transform, shade);
        return true;
    }

    void box(const Vector3 &lo, const Vector3 &hi, int64_t material, const Color &color,
             int64_t skip, const Transform3D &transform, bool shade) {
        const real_t x0 = lo.x, y0 = lo.y, z0 = lo.z, x1 = hi.x, y1 = hi.y, z1 = hi.z;
        if (!(skip & 2)) polygon({{x0,y1,z0}, {x1,y1,z0}, {x1,y1,z1}, {x0,y1,z1}}, {0,1,0}, nullptr, material, color, transform, shade);
        if (!(skip & 1)) polygon({{x0,y0,z0}, {x1,y0,z0}, {x1,y0,z1}, {x0,y0,z1}}, {0,-1,0}, nullptr, material, color, transform, shade);
        if (!(skip & 4)) polygon({{x0,y0,z0}, {x1,y0,z0}, {x1,y1,z0}, {x0,y1,z0}}, {0,0,-1}, nullptr, material, color, transform, shade);
        if (!(skip & 8)) polygon({{x0,y0,z1}, {x1,y0,z1}, {x1,y1,z1}, {x0,y1,z1}}, {0,0,1}, nullptr, material, color, transform, shade);
        if (!(skip & 16)) polygon({{x0,y0,z0}, {x0,y0,z1}, {x0,y1,z1}, {x0,y1,z0}}, {-1,0,0}, nullptr, material, color, transform, shade);
        if (!(skip & 32)) polygon({{x1,y0,z0}, {x1,y0,z1}, {x1,y1,z1}, {x1,y1,z0}}, {1,0,0}, nullptr, material, color, transform, shade);
    }

    void add_vertex(const Vector3 &p, const Vector3 &normal, const Vector2 &uv,
                    const Vector2 &layer, const Color &color, bool shade) {
        cached.clear();
        vertex(p, normal, uv, layer, color, shade);
    }

    Array arrays() {
        if (cached.is_empty()) {
            cached.resize(Mesh::ARRAY_MAX);
            cached[Mesh::ARRAY_VERTEX] = packed<PackedVector3Array>(positions);
            cached[Mesh::ARRAY_NORMAL] = packed<PackedVector3Array>(normals);
            cached[Mesh::ARRAY_TEX_UV] = packed<PackedVector2Array>(uvs);
            cached[Mesh::ARRAY_TEX_UV2] = packed<PackedVector2Array>(layers);
            cached[Mesh::ARRAY_COLOR] = packed<PackedColorArray>(colors);
        }
        // Return a separate outer Array; consumers cannot replace our cached channels.
        return cached.duplicate();
    }
};

static void initialize(ModuleInitializationLevel level) {
    if (level == MODULE_INITIALIZATION_LEVEL_SCENE) {
        ClassDB::register_class<MCFMeshBuilder>();
        register_visibility_kernel();
        register_pathfinding_kernel();
        register_ai_kernel();
        register_terrain_kernel();
    }
}
static void terminate(ModuleInitializationLevel) {}
extern "C" GDExtensionBool GDE_EXPORT mcf_visuals_init(GDExtensionInterfaceGetProcAddress proc,
        GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(proc, library, initialization);
    init.register_initializer(initialize);
    init.register_terminator(terminate);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
