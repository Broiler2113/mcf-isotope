#include "runtime.hpp"
#include <array>
#include <cmath>
#include <stdexcept>

namespace mcf {
Runtime::Runtime(const void *data, size_t size) {
    options.SetIntraOpNumThreads(2);
    options.SetInterOpNumThreads(1);
    options.SetExecutionMode(ExecutionMode::ORT_SEQUENTIAL);
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    session=std::make_unique<Ort::Session>(env,data,size,options);
    Ort::AllocatorWithDefaultOptions allocator;
    const std::array<const char *,4> names={"grid","flat","cand","cells"};
    const std::array<std::vector<int64_t>,4> shapes={{{1,N_CHANNELS,-1,-1},{1,FLAT_DIM},{1,-1,CAND_DIM},{1,-1,2}}};
    if(session->GetInputCount()!=4 || session->GetOutputCount()!=2) throw std::runtime_error("policy must have four inputs and two outputs");
    for(size_t i=0;i<4;++i) {
        auto name=session->GetInputNameAllocated(i,allocator);
        auto type_info=session->GetInputTypeInfo(i);
        auto tensor=type_info.GetTensorTypeAndShapeInfo();
        auto dims=tensor.GetShape();
        if(std::string(name.get())!=names[i] || dims.size()!=shapes[i].size() ||
           tensor.GetElementType()!=(i==3 ? ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 : ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT))
            throw std::runtime_error("incompatible policy input: "+std::string(names[i]));
        for(size_t d=0;d<dims.size();++d) if(shapes[i][d]>=0 && dims[d]!=shapes[i][d])
            throw std::runtime_error("incompatible policy feature layout");
    }
    for(size_t i=0;i<2;++i) {
        auto name=session->GetOutputNameAllocated(i,allocator);
        if(std::string(name.get())!=(i==0 ? "logits" : "value")) throw std::runtime_error("incompatible policy outputs");
    }
}
Json Runtime::metadata() const {
    Json result=Json::object();
    Ort::AllocatorWithDefaultOptions allocator;
    auto meta=session->GetModelMetadata();
    for(const auto *key:{"mcf.label","mcf.round_cap","mcf.max_actors","mcf.max_candidates","mcf.feature_version"}) {
        auto value=meta.LookupCustomMetadataMapAllocated(key,allocator);
        if(value) result[key]=value.get();
    }
    return result;
}
Prediction Runtime::infer(Tensors &t) {
    const int64_t n=static_cast<int64_t>(t.count), c=t.canvas;
    std::array<int64_t,4> gs{1,N_CHANNELS,c,c};
    std::array<int64_t,2> fs{1,FLAT_DIM};
    std::array<int64_t,3> cs{1,n,CAND_DIM}, is{1,n,2};
    std::array<Ort::Value,4> inputs{
        Ort::Value::CreateTensor<float>(memory,t.grid.data(),t.grid.size(),gs.data(),gs.size()),
        Ort::Value::CreateTensor<float>(memory,t.flat.data(),t.flat.size(),fs.data(),fs.size()),
        Ort::Value::CreateTensor<float>(memory,t.cand.data(),t.cand.size(),cs.data(),cs.size()),
        Ort::Value::CreateTensor<int64_t>(memory,t.cells.data(),t.cells.size(),is.data(),is.size())};
    const char *names[]={"grid","flat","cand","cells"}, *out[]={"logits","value"};
    auto values=session->Run(Ort::RunOptions{nullptr},names,inputs.data(),4,out,2);
    if(!values[0].IsTensor() || !values[1].IsTensor()) throw std::runtime_error("policy outputs must be tensors");
    auto logits_info=values[0].GetTensorTypeAndShapeInfo(), value_info=values[1].GetTensorTypeAndShapeInfo();
    if(logits_info.GetElementType()!=ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || value_info.GetElementType()!=ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT ||
       logits_info.GetShape()!=std::vector<int64_t>{n} || value_info.GetElementCount()!=1)
        throw std::runtime_error("invalid policy output shape/type");
    const float *data=values[0].GetTensorData<float>();
    Prediction p{-1,*values[1].GetTensorData<float>(),std::vector<float>(data,data+t.count)};
    if(!std::isfinite(p.value)) throw std::runtime_error("policy returned non-finite value");
    p.action=greedy_action(p.logits,t);
    return p;
}
}
