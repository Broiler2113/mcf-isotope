// Test/benchmark tool: same encoder and runtime as the GDExtension, JSON lines on stdin.
#include "runtime.hpp"
#include <chrono>
#include <fstream>
#include <iostream>
#include <iterator>

template<class T> void dump(const std::string &path,const std::vector<T> &v) {
    std::ofstream f(path,std::ios::binary);
    f.write(reinterpret_cast<const char *>(v.data()),v.size()*sizeof(T));
    if(!f) throw std::runtime_error("cannot write tensor dump");
}
int main(int argc,char **argv) {
    try {
        std::unique_ptr<mcf::Runtime> runtime;
        if(argc>1) {
            std::ifstream f(argv[1],std::ios::binary);
            std::vector<char> data((std::istreambuf_iterator<char>(f)),{});
            runtime=std::make_unique<mcf::Runtime>(data.data(),data.size());
        }
        std::string line;
        while(std::getline(std::cin,line)) {
            try {
                auto req=mcf::Json::parse(line);
                auto start=std::chrono::steady_clock::now();
                auto t=mcf::encode(req);
                auto encoded=std::chrono::steady_clock::now();
                mcf::Json out{{"canvas",t.canvas},{"n",t.count}};
                if(runtime) {
                    auto p=runtime->infer(t);
                    out["action"]=p.action; out["value"]=p.value; out["logits"]=p.logits;
                }
                auto finished=std::chrono::steady_clock::now();
                out["encode_ms"]=std::chrono::duration<double,std::milli>(encoded-start).count();
                out["infer_ms"]=std::chrono::duration<double,std::milli>(finished-encoded).count();
                if(req.contains("dump")) {
                    auto prefix=req.at("dump").get<std::string>();
                    dump(prefix+".grid",t.grid); dump(prefix+".flat",t.flat);
                    dump(prefix+".cand",t.cand); dump(prefix+".cells",t.cells);
                }
                if(req.contains("test_logits")) out["test_action"]=mcf::greedy_action(req.at("test_logits").get<std::vector<float>>(),t);
                std::cout<<out.dump()<<std::endl;
            } catch(const std::exception &e) { std::cout<<mcf::Json({{"error",e.what()}}).dump()<<std::endl; }
        }
    } catch(const std::exception &e) { std::cerr<<e.what()<<std::endl; return 1; }
}
