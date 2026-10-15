#include "features.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <map>
#include <set>
#include <stdexcept>

namespace mcf {
namespace {
double number(const Json &j) {
    if (j.is_boolean()) return j.get<bool>() ? 1.0 : 0.0;
    return j.get<double>();
}
double get(const Json &j, const char *key, double fallback = 0) {
    return j.contains(key) ? number(j.at(key)) : fallback;
}
int integer(const Json &j, const char *key) { return static_cast<int>(number(j.at(key))); }
int index_of(const std::vector<std::string> &items, const std::string &key) {
    auto it = std::find(items.begin(), items.end(), key);
    return it == items.end() ? -1 : static_cast<int>(it - items.begin());
}
void require(bool condition, const std::string &message) {
    if (!condition) throw std::invalid_argument(message);
}
using Point = std::pair<int, int>;
int distance(Point a, Point b) { return std::max(std::abs(a.first-b.first), std::abs(a.second-b.second)); }
}

Tensors encode(const Json &request) {
    const auto &o = request.at("obs");
    const auto &legal = request.at("legal");
    const int w = integer(o, "w"), h = integer(o, "h");
    require(w > 0 && h > 0 && w <= 256 && h <= 256, "policy board must be within 1..256 cells");
    require(legal.is_array() && !legal.empty() && legal.size() <= 1000000, "invalid legal candidate count");
    Tensors t;
    t.canvas = std::max(CANVAS, ((std::max(w,h) + 15) / 16) * 16);
    t.count = legal.size();
    const int canvas = t.canvas, area = canvas*canvas, ox = (canvas-w)/2, oy = (canvas-h)/2;
    t.grid.assign(N_CHANNELS*area, 0);
    t.flat.assign(FLAT_DIM, 0);
    t.cand.assign(t.count*CAND_DIM, 0);
    t.cells.assign(t.count*2, -1);
    auto put = [&](int channel, int x, int y, double value) {
        require(channel >= 0 && channel < N_CHANNELS, "grid channel out of range");
        t.grid[channel*area + (y+oy)*canvas + x+ox] = static_cast<float>(value);
    };
    auto plane = [&](const char *key, int channel, double scale, double ceiling, bool int_input) {
        const auto &p = o.at(key);
        require(p.is_array() && p.size() == size_t(w*h), std::string("invalid plane: ")+key);
        for (int y=0; y<h; ++y) for (int x=0; x<w; ++x) {
            double v = number(p[y*w+x]);
            // Python's terrain/tactical planes use int32; optional hazard planes use float32.
            v = int_input ? static_cast<int32_t>(v) : static_cast<float>(v);
            put(channel, x, y, std::min(v/scale, ceiling));
        }
    };
    for (const auto *key : {"floor","feat","feat_own","fog"}) {
        const auto &p = o.at(key);
        require(p.is_array() && p.size()==size_t(w*h), std::string("invalid plane: ")+key);
    }
    for (int y=0; y<h; ++y) for (int x=0; x<w; ++x) {
        const int i = y*w+x;
        put(C_VALID,x,y,1);
        int floor = static_cast<int>(number(o.at("floor")[i]));
        int feat = static_cast<int>(number(o.at("feat")[i]));
        int own = static_cast<int>(number(o.at("feat_own")[i]));
        int fog = static_cast<int>(number(o.at("fog")[i]));
        if (floor>=1 && floor<=3) put(C_FLOOR+floor-1,x,y,1);
        if (floor==3) put(C_SPACE,x,y,1); // Deliberately duplicates the grass plane, as in Python.
        if (feat>=1 && feat<=N_FEATURES) put(C_FEAT+feat-1,x,y,1);
        if (own>=1 && own<=3) put(C_FEAT_OWN+own-1,x,y,1);
        if (fog>=0 && fog<3) put(C_FOG+fog,x,y,1);
    }
    const double inf = std::numeric_limits<double>::infinity();
    plane("cover",C_COVER,4,inf,true); plane("fire",C_FIRE,1,inf,true);
    plane("corpse",C_CORPSE,5,inf,true); plane("dirt",C_DIRT,2,inf,true);
    plane("veh",C_VEH_FOOT,1,inf,true);
    for (auto p : std::vector<std::pair<const char *, int>>{{"gas",C_GAS},{"gas_warning",C_GAS_WARNING},
            {"artillery_warning",C_ARTILLERY_WARNING},{"vcrush",C_VEH_CRUSH},
            {"smoke",C_SMOKE},{"wave_warning",C_WAVE_WARNING}})
        if (o.contains(p.first)) plane(p.first,p.second,p.second==C_VEH_CRUSH ? 4 : 1,inf,false);
    if (o.contains("zone")) {
        const auto &z=o.at("zone");
        require(z.is_array() && z.size()==size_t(w*h), "invalid zone plane");
        for (int y=0;y<h;++y) for(int x=0;x<w;++x) {
            int v=static_cast<int>(number(z[y*w+x]));
            put(C_ZONE,x,y,v>0); put(C_ZONE_OURS,x,y,v==2); put(C_ZONE_THEIRS,x,y,v==3);
        }
    }
    if(o.contains("threat")) { plane("threat",C_THREAT,24,1,true); plane("fcover",C_FCOVER,24,1,true); }
    if(o.contains("dthreat")) plane("dthreat",C_DRONE_THREAT,4,1,true);
    if(o.contains("fnext")) {
        plane("fnext",C_FNEXT,24,1,true); plane("ereach",C_EREACH,24,1,true);
        if(o.contains("lastseen") && o.at("lastseen").size()==size_t(w*h)) plane("lastseen",C_LASTSEEN,100,inf,true);
    }
    const auto &units=o.at("units"), &vehicles=o.at("vehicles");
    for(const auto &u: units) {
        int x=integer(u,"x"), y=integer(u,"y");
        if(x<0 || y<0 || x>=w || y>=h) continue;
        int own=integer(u,"own"), type=integer(u,"type");
        require(own>=0 && own<3 && type>=0 && type<N_UNIT_TYPES,"invalid unit type/owner");
        put(C_UNIT_OWN+own,x,y,1); put(C_UNIT_TYPE+type,x,y,1);
        put(C_UNIT_AP,x,y,get(u,"ap")/std::max(1.0,get(u,"max_ap")));
        put(C_UNIT_HELD,x,y,get(u,"held")); put(C_UNIT_CORPSES,x,y,get(u,"corpses"));
        put(C_UNIT_ITEM,x,y,!u.at("item").empty() && u.at("item")!=false && u.at("item")!=0);
        put(C_UNIT_CIV,x,y,get(u,"civ")); put(C_UNIT_PENDING,x,y,get(u,"pending")/8);
        put(C_UNIT_MC,x,y,std::min(get(u,"mc"),16.0)/16);
    }
    for(const auto &v: vehicles) {
        int vw=integer(v,"w"), vh=integer(v,"h"), own=integer(v,"own"), type=integer(v,"type");
        require(vw>=0 && vh>=0 && vw<=256 && vh<=256 && own>=0 && own<3 && type>=0 && type<N_VEH_TYPES,"invalid vehicle");
        const auto &comps=v.at("comps");
        auto hull=comps.value("hull",Json::array({1,1}));
        for(int dy=0;dy<vh;++dy) for(int dx=0;dx<vw;++dx) {
            int x=integer(v,"x")+dx, y=integer(v,"y")+dy;
            if(x<0 || y<0 || x>=w || y>=h) continue;
            put(C_VEH_OWN+own,x,y,1); put(C_VEH_TYPE+type,x,y,1);
            put(C_VEH_HULL,x,y,number(hull.at(0))/std::max(1.0,number(hull.at(1))));
            put(C_VEH_FX,x,y,get(v,"fx")); put(C_VEH_FY,x,y,get(v,"fy")); put(C_VEH_WRECK,x,y,get(v,"wrecked"));
            for(size_t j=0;j<VEH_COMPONENTS.size();++j) if(comps.contains(VEH_COMPONENTS[j])) {
                const auto &hp=comps.at(VEH_COMPONENTS[j]);
                put(C_VEH_COMPONENT+j,x,y,number(hp.at(0))/std::max(1.0,number(hp.at(1))));
                put(C_VEH_COMPONENT+VEH_COMPONENTS.size()+j,x,y,1);
            }
            put(C_VEH_CREW,x,y,get(v,"crew")/std::max(1.0,get(v,"cap",1)));
            put(C_VEH_AP,x,y,std::min(get(v,"ap"),16.0)/16);
        }
    }
    auto &f=t.flat;
    double cap=std::max(1.0,get(o,"round_cap")), total=get(o,"my_value")+get(o,"enemy_value");
    f[0]=get(o,"round")/cap; f[1]=cap/20; f[2]=get(o,"slot")/std::max(1.0,get(o,"slots"));
    f[3]=get(o,"my_value")/5000; f[4]=get(o,"enemy_value")/5000;
    f[5]=total>0 ? (get(o,"my_value")-get(o,"enemy_value"))/total : 0;
    f[6]=get(o,"combat_started");
    int fog=integer(o,"fog_mode"), mode=static_cast<int>(get(o,"mode"));
    require(fog>=0 && fog<3 && mode>=0,"invalid fog/game mode");
    f[7+fog]=1;
    int counts[3]={0,0,0}, veh_counts[2]={0,0}; double ap=0;
    for(const auto &u:units) {
        int own=integer(u,"own"); require(own>=0 && own<3,"invalid unit owner");
        ++counts[own]; if(own==0) ap+=get(u,"ap");
    }
    for(const auto &v:vehicles) if(integer(v,"own")<2 && integer(v,"own")>=0) ++veh_counts[integer(v,"own")];
    for(int j=0;j<3;++j) f[10+j]=counts[j]/20.0;
    f[13]=ap/40; f[14]=veh_counts[0]/4.0; f[15]=veh_counts[1]/4.0;
    f[16]=get(o,"side"); f[17]=double(w)/CANVAS; f[18]=double(h)/CANVAS; f[19]=1;
    f[20+std::min(2,mode)]=1;
    double target=std::max(1.0,get(o,"pts_target")), waves=get(o,"waves_total");
    f[23]=get(o,"pts")/target; f[24]=get(o,"pts_enemy")/target;
    f[25]=get(o,"wave")/std::max(1.0,waves==0 ? 20 : waves);
    f[26]=get(o,"wave_pending"); f[27]=get(o,"wave_left")/20;

    std::map<int,const Json *> vehicle_ids;
    std::vector<const Json *> hostile;
    std::vector<Point> goals;
    std::set<Point> own_cells;
    for(const auto &u:units) {
        Point p{integer(u,"x"),integer(u,"y")};
        if(integer(u,"own")==1 && !get(u,"aboard") && p.first>=0 && p.second>=0 && p.first<w && p.second<h) goals.push_back(p);
        if(integer(u,"own")==0 && !get(u,"aboard")) own_cells.insert(p);
    }
    for(const auto &v:vehicles) {
        if(v.contains("id")) vehicle_ids[integer(v,"id")]=&v;
        if(integer(v,"own")==1 && get(v,"alive",1)) {
            hostile.push_back(&v);
            goals.emplace_back(integer(v,"x")+integer(v,"w")/2,integer(v,"y")+integer(v,"h")/2);
        }
    }
    if(goals.empty()) goals.emplace_back(w/2,h/2);
    auto near_allies=[&](Point p) { int n=0; for(int dy=-2;dy<=2;++dy) for(int dx=-2;dx<=2;++dx) n+=own_cells.count({p.first+dx,p.second+dy}); return n; };
    std::map<Point,std::vector<Point>> actor_goals;
    for(size_t i=0;i<t.count;++i) {
        const auto &c=legal[i], &wire=c.at("i");
        const std::string kind=wire.value("t",std::string());
        float *r=t.cand.data()+i*CAND_DIM;
        r[F_KIND+std::max(0,index_of(INTENT_KINDS,kind))]=1;
        auto one_hot=[&](const char *key,int base,int limit) {
            if(c.contains(key) && !c.at(key).is_null()) { int v=integer(c,key); if(v>=0) { require(v<limit,"candidate type out of range"); r[base+v]=1; } }
        };
        one_hot("at",F_ACTOR_TYPE,N_ACTOR_TYPES); one_hot("tt",F_TARGET_TYPE,N_UNIT_TYPES);
        int ax=integer(c,"ax"), ay=integer(c,"ay"), tx=integer(c,"tx"), ty=integer(c,"ty");
        auto cell=[&](int x,int y) {
            // In-bounds actors and targets are the only gather references emitted by ObsEncoder.
            require(x<w && y>=0 && y<h,"candidate cell outside board");
            return int64_t((y+oy)*canvas+x+ox);
        };
        if(ax>=0) { r[F_GEOM]=double(ax)/w; r[F_GEOM+1]=double(ay)/h; t.cells[i*2]=cell(ax,ay); }
        if(tx>=0) {
            r[F_GEOM+2]=double(tx)/w; r[F_GEOM+3]=double(ty)/h; r[F_GEOM+7]=1; t.cells[i*2+1]=cell(tx,ty);
            if(ax>=0) { r[F_GEOM+4]=(tx-ax)/32.0; r[F_GEOM+5]=(ty-ay)/32.0; r[F_GEOM+6]=std::max(std::abs(tx-ax),std::abs(ty-ay))/32.0; }
        }
        if(kind=="shoot" || kind=="rsp") {
            r[F_MISC]=wire.contains("s") && !wire.at("s").is_null() && number(wire.at("s"))==-1;
            r[F_MISC+1]=wire.contains("s") && !wire.at("s").is_null() && number(wire.at("s"))==1;
        } else if(wire.contains("s") && !wire.at("s").is_null()) r[F_MISC+3]=get(wire,"s")/16;
        r[F_MISC+2]=get(wire,"av");
        std::string comp=wire.value("cm",std::string()), build=wire.value("f",std::string());
        r[F_MISC+4]=!comp.empty();
        int j=index_of(VEH_COMPONENTS,comp);
        if(j>=0) {
            r[F_COMPONENT+j]=1;
            auto v=wire.contains("v") && !wire.at("v").is_null() ? vehicle_ids.find(integer(wire,"v")) : vehicle_ids.end();
            if(v!=vehicle_ids.end() && v->second->at("comps").contains(comp)) {
                const auto &hp=v->second->at("comps").at(comp);
                r[F_COMPONENT_HEALTH]=number(hp.at(0))/std::max(1.0,number(hp.at(1))); r[F_COMPONENT_HEALTH+1]=1;
            }
        }
        j=index_of(BUILD_FEATURES,build); if(j>=0) r[F_MISC+5+j]=1;
        r[F_DRONE]=get(c,"lf"); r[F_DRONE+1]=std::min(get(c,"vh"),9.0)/9;
        if(c.contains("th")) { r[F_TAC]=std::min(get(c,"th"),6.0)/6; r[F_TAC+1]=std::min(get(c,"fc"),6.0)/6; r[F_TAC+2]=get(c,"cv")/2; }
        if(c.contains("tn")) { r[F_PRED]=std::min(get(c,"tn"),6.0)/6; r[F_PRED+1]=std::min(get(c,"er"),6.0)/6; }
        r[F_REACH]=get(c,"rh");
        for(auto p:std::vector<std::pair<const char *,int>>{{"hazard",F_HAZARD},{"vc",F_VEH_CRUSH}}) if(c.contains(p.first)) {
            const auto &vals=c.at(p.first); int n=p.second==F_HAZARD ? 6 : 2;
            require(vals.is_array() && vals.size()==size_t(n),"invalid candidate hazard features");
            for(int k=0;k<n;++k) r[p.second+k]=number(vals[k]);
        }
        if(std::max(w,h)>=100 && kind=="move" && ax>=0 && tx>=0) {
            Point a{ax,ay}, target_cell{tx,ty};
            if(!actor_goals.count(a)) {
                auto nearby=goals;
                std::stable_sort(nearby.begin(),nearby.end(),[&](Point x,Point y){return distance(a,x)<distance(a,y);});
                if(nearby.size()>8) nearby.resize(8);
                actor_goals[a]=std::move(nearby);
            }
            auto nearest=[&](Point p){int d=INT32_MAX;for(Point g:actor_goals[a]) d=std::min(d,distance(p,g));return d;};
            r[F_ADVANCE]=std::clamp((nearest(a)-nearest(target_cell))/8.0,-1.0,1.0);
            r[F_SPACING]=std::clamp((near_allies(a)-near_allies(target_cell))/10.0,-1.0,1.0);
        }
        if((kind=="shoot" || kind=="veh_cannon") && tx>=0) {
            bool on_hull=false;
            for(auto v:hostile) if(integer(*v,"x")<=tx && tx<integer(*v,"x")+integer(*v,"w") && integer(*v,"y")<=ty && ty<integer(*v,"y")+integer(*v,"h")) on_hull=true;
            bool ally=false; for(Point p:own_cells) if(distance({tx,ty},p)<=2) { ally=true; break; }
            if(on_hull && !ally) r[F_COUNTER_TANK]=(comp=="tracks_l" || comp=="tracks_r") ? 1.25f : 1.0f;
        }
        int apc=static_cast<int>(get(c,"apc"));
        if(apc) { r[F_TAC+3]=apc/3.0; r[F_TAC+4]=apc>=2; }
    }
    return t;
}

int greedy_action(const std::vector<float> &logits, const Tensors &t) {
    require(logits.size()==t.count && t.count>0,"invalid logits count");
    double maxes[2]={-INFINITY,-INFINITY}, sums[2]={0,0}; int best[2]={-1,-1};
    for(size_t i=0;i<t.count;++i) {
        require(std::isfinite(logits[i]),"policy returned non-finite logits");
        int branch=t.cand[i*CAND_DIM+F_KIND]>.5f ? 0 : 1;
        if(logits[i]>maxes[branch]) { maxes[branch]=logits[i]; best[branch]=static_cast<int>(i); }
    }
    for(size_t i=0;i<t.count;++i) { int b=t.cand[i*CAND_DIM+F_KIND]>.5f ? 0 : 1; sums[b]+=std::exp(double(logits[i])-maxes[b]); }
    double stop=maxes[0]+std::log(sums[0]), act=maxes[1]+std::log(sums[1]);
    return stop>=act ? best[0] : best[1];
}
}
