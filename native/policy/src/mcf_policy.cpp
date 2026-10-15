#include "runtime.hpp"
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/dictionary.hpp>

using namespace godot;
namespace {
// Convert once at the native boundary. Dense tensors stay entirely in C++.
mcf::Json to_json(const Variant &v) {
    switch(v.get_type()) {
        case Variant::NIL: return nullptr;
        case Variant::BOOL: return static_cast<bool>(v);
        case Variant::INT: return static_cast<int64_t>(v);
        case Variant::FLOAT: return static_cast<double>(v);
        case Variant::STRING: return std::string(String(v).utf8().get_data());
        case Variant::DICTIONARY: {
            Dictionary d=v; auto keys=d.keys(); auto out=mcf::Json::object();
            for(int i=0;i<keys.size();++i) out[std::string(String(keys[i]).utf8().get_data())]=to_json(d[keys[i]]);
            return out;
        }
        case Variant::ARRAY: {
            Array a=v; auto out=mcf::Json::array();
            for(int i=0;i<a.size();++i) out.push_back(to_json(a[i]));
            return out;
        }
        case Variant::PACKED_INT32_ARRAY: {
            PackedInt32Array a=v;
            if(a.is_empty()) return mcf::Json::array();
            return mcf::Json(std::vector<int32_t>(a.ptr(),a.ptr()+a.size()));
        }
        case Variant::PACKED_FLOAT32_ARRAY: {
            PackedFloat32Array a=v;
            if(a.is_empty()) return mcf::Json::array();
            return mcf::Json(std::vector<float>(a.ptr(),a.ptr()+a.size()));
        }
        default: throw std::invalid_argument("unsupported policy request type");
    }
}
Dictionary error(const std::exception &e) { Dictionary d; d["error"]=String::utf8(e.what()); return d; }
}
class MCFPolicy : public RefCounted {
    GDCLASS(MCFPolicy,RefCounted)
    std::unique_ptr<mcf::Runtime> runtime;
protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("load_model","path"),&MCFPolicy::load_model);
        ClassDB::bind_method(D_METHOD("infer","request"),&MCFPolicy::infer);
    }
public:
    Dictionary load_model(const String &path) {
        runtime.reset();
        try {
            auto file=FileAccess::open(path,FileAccess::READ);
            if(file.is_null()) throw std::runtime_error("cannot open ONNX model: "+std::string(path.utf8().get_data()));
            auto bytes=file->get_buffer(file->get_length());
            runtime=std::make_unique<mcf::Runtime>(bytes.ptr(),bytes.size());
            Dictionary d; d["ok"]=true;
            auto meta=runtime->metadata();
            for(auto it=meta.begin();it!=meta.end();++it) d[String::utf8(it.key().c_str())]=String::utf8(it.value().get<std::string>().c_str());
            return d;
        } catch(const std::exception &e) { runtime.reset(); return error(e); }
    }
    Dictionary infer(const Dictionary &request) {
        try {
            if(!runtime) throw std::runtime_error("ONNX model is not loaded");
            auto tensors=mcf::encode(to_json(request));
            auto p=runtime->infer(tensors);
            Dictionary d; d["action"]=p.action; d["value"]=p.value; return d;
        } catch(const std::exception &e) { return error(e); }
    }
};
static void initialize(ModuleInitializationLevel level) {
    if(level==MODULE_INITIALIZATION_LEVEL_SCENE) ClassDB::register_class<MCFPolicy>();
}
static void terminate(ModuleInitializationLevel) {}
extern "C" GDExtensionBool GDE_EXPORT mcf_policy_init(GDExtensionInterfaceGetProcAddress proc,
        GDExtensionClassLibraryPtr library,GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(proc,library,initialization);
    init.register_initializer(initialize); init.register_terminator(terminate);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
