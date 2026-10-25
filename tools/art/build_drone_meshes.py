#!/usr/bin/env python3
"""Low-poly drone models in the SVAROG tank's manner: simple solids on one realistic,
pixelated texture atlas, the top plate marked TeamStripe for the side's colour.

    python3 tools/art/build_drone_meshes.py        (numpy + PIL)
    godot --headless --editor --path . --import
    xvfb-run -a godot --path . --rendering-method gl_compatibility --script res://tools/art/build_drone_sprites.gd

Writes assets/models/drone/{kamikaze,scout}.obj, drone.mtl and atlas.png. Metres, Y up,
nose along +X, centred on the body (FirstPerson hangs the model by its centre).
"""
from math import cos, sin, pi, radians
from pathlib import Path

import numpy as np
from PIL import Image

import build_first_person as A

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets/models/drone"
ATLAS = 128            # px; regions are 32 px squares, about 120 px a metre on the model
D = 120.0              # texels a metre on the model
R = {                  # atlas regions: x, y, w, h (px)
    "carbon": (0, 0, 64, 32), "motor": (64, 0, 32, 32), "prop": (96, 0, 32, 32),
    "paint": (0, 32, 64, 32), "camera": (64, 32, 32, 32), "lens": (96, 32, 32, 32),
    "warhead": (0, 64, 64, 32), "tape": (64, 64, 32, 32), "antenna": (96, 64, 32, 32),
    "scout": (0, 96, 64, 32), "vent": (64, 96, 32, 32), "led": (96, 96, 32, 32),
}


# --- texture atlas ------------------------------------------------------------------------------------
def atlas():
    S = A.SS
    h = w = ATLAS * S
    out = np.zeros((h, w, 3), np.float32)

    def region(name, make):
        x, y, rw, rh = R[name]
        hh, ww = rh * S, rw * S
        out[y * S:(y + rh) * S, x * S:(x + rw) * S] = make(hh, ww)

    def flat(c, var, seed, scale=0.2):
        def f(hh, ww):
            return A.col(A.rgb(c), hh, ww) * (1 + var * A.noise(hh, ww, seed, scale, beta=0.5))[..., None]
        return f

    def worn(base, seed, scratches=40, grime=0.2):
        def f(hh, ww):
            c = base(hh, ww)
            c = c + A.scratches(hh, ww, seed, scratches, 0.15, 0.22)[..., None]
            c = c * A.grime(hh, ww, seed + 1, 0.3, grime)[..., None]
            return A.shade(c, 0.002 * A.noise(hh, ww, seed + 2, 0.06), A.SKY, gloss=0.08)
        return f

    def carbon(hh, ww):
        x, y = A.grid(hh, ww)
        weave = np.sign(np.sin((x + y) * 2 * np.pi / 0.18)) * np.sign(np.sin((x - y) * 2 * np.pi / 0.18))
        c = A.col(A.rgb("1b1c1e"), hh, ww) * (1 + 0.15 * weave + 0.1 * A.noise(hh, ww, 11, 0.3))[..., None]
        return worn(lambda *_: c, 12, 60, 0.1)(hh, ww)

    def motor(hh, ww):
        x, y = A.grid(hh, ww)
        c = A.col(A.rgb("2a2b2e"), hh, ww)
        coil = (np.abs(((x * 8) % 1) - 0.5) < 0.2) & (y > 0.35) & (y < 0.8)
        c = np.where(coil[..., None], A.col(A.rgb("8a5530"), hh, ww), c)
        bell = y < 0.35
        c = np.where(bell[..., None], A.col(A.rgb("8d9095"), hh, ww) * (1 + 0.1 * A.noise(hh, ww, 21, 0.03, sx=8))[..., None], c)
        return worn(lambda *_: c, 22, 20, 0.15)(hh, ww)

    def warhead(hh, ww):
        x, y = A.grid(hh, ww)
        c = A.col(A.rgb("545a36"), hh, ww) * (1 + 0.08 * A.noise(hh, ww, 31, 0.3, beta=1))[..., None]
        band = np.abs(x - 0.62) < 0.06
        c = np.where(band[..., None], A.col(A.rgb("a88a2a"), hh, ww), c)
        text = (y > 0.3) & (y < 0.45) & (x > 0.1) & (x < 0.5) & (A.hash2(np.floor(x / 0.07), 0, 32) > 0.3) & (((x / 0.07) % 1) > 0.3)
        c = A.mix(c, A.rgb("141410"), text * 0.8)
        chip = A.sstep(1.7, 2.3, A.noise(hh, ww, 33, 0.06))
        c = A.mix(c, A.rgb("7d7b74"), chip)
        return worn(lambda *_: c, 34, 50, 0.25)(hh, ww)

    def tape(hh, ww):
        x, y = A.grid(hh, ww)
        c = A.col(A.rgb("3d4430"), hh, ww) * (1 + 0.1 * A.noise(hh, ww, 41, 0.04, sy=6) + 0.06 * np.sin(y * 2 * np.pi / 0.12))[..., None]
        return A.shade(c, 0.003 * A.noise(hh, ww, 42, 0.15), A.SKY)

    def lens(hh, ww):
        x, y = A.grid(hh, ww)
        r = np.hypot(x - 0.5, y - 0.5) / 0.48
        c = A.mix(A.col(A.rgb("0a1a26"), hh, ww), A.col(A.rgb("3d6f8f"), hh, ww), np.clip(1 - r, 0, 1) * 0.6)
        glint = np.hypot(x - 0.36, y - 0.36) < 0.08
        return np.where(glint[..., None], A.col(A.rgb("dfe9f0"), hh, ww), c)

    def vent(hh, ww):
        x, y = A.grid(hh, ww)
        slot = ((y * 8) % 1) < 0.45
        c = A.col(A.rgb("4a4d4f"), hh, ww) * np.where(slot, 0.35, 1.0)[..., None]
        return A.shade(c, np.where(slot, -0.001, 0.0), A.SKY)

    def led(hh, ww):
        x, y = A.grid(hh, ww)
        c = A.col(A.rgb("15161a"), hh, ww)
        dot = np.hypot(x - 0.5, y - 0.5) < 0.25
        return np.where(dot[..., None], A.col(A.rgb("ff4a2a"), hh, ww), c)

    region("carbon", carbon)
    region("motor", motor)
    region("prop", worn(flat("141416", 0.08, 51), 52, 15, 0.05))
    region("paint", worn(flat("9ea29a", 0.06, 61, 0.05), 62, 50, 0.2))      # the team colour paints over this
    region("camera", worn(flat("2e3033", 0.08, 71), 72, 20, 0.1))
    region("lens", lens)
    region("warhead", warhead)
    region("tape", tape)
    region("antenna", worn(flat("101010", 0.05, 81), 82, 5, 0.05))
    region("scout", worn(flat("6f7579", 0.07, 91, 0.06), 92, 70, 0.25))
    region("vent", vent)
    region("led", led)
    return A.down(out)


# --- low-poly mesh writer ---------------------------------------------------------------------------------
class Obj:
    def __init__(self):
        self.v, self.vt, self.vn = [], [], []
        self.faces = {}

    def _uv(self, region, u, v):
        x, y, w, h = R[region]
        return ((x + min(u, w - 0.5)) / ATLAS, 1 - (y + min(v, h - 0.5)) / ATLAS)

    def poly(self, pts, region, mat="Drone"):
        """A flat polygon (counter-clockwise from outside), textured by planar projection at D
        texels a metre, centred in its atlas region."""
        p = [np.asarray(q, float) for q in pts]
        n = np.cross(p[1] - p[0], p[2] - p[0])
        n /= np.linalg.norm(n)
        ex = p[1] - p[0]
        ex /= np.linalg.norm(ex)
        ey = np.cross(n, ex)
        base = len(self.v)
        self.vn.append(n)
        ni = len(self.vn)
        idx = []
        us = [np.dot(q - p[0], ex) for q in p]
        vs = [np.dot(q - p[0], ey) for q in p]
        u0, v0 = min(us), min(vs)
        _, _, rw, rh = R[region]
        offset = (max(0.5, (rw - (max(us) - u0) * D) / 2), max(0.5, (rh - (max(vs) - v0) * D) / 2))
        for q, u, v in zip(p, us, vs):
            self.v.append(q)
            self.vt.append(self._uv(region, offset[0] + (u - u0) * D, offset[1] + (v - v0) * D))
            idx.append((len(self.v), len(self.vt), ni))
        self.faces.setdefault(mat, []).append(idx)

    def box(self, lo, hi, region, mat="Drone", yaw=0.0, at=(0, 0, 0), top=None, top_region=None):
        x0, y0, z0 = lo
        x1, y1, z1 = hi
        c = [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0), (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]
        ca, sa = cos(yaw), sin(yaw)
        c = [(at[0] + x * ca - z * sa, at[1] + y, at[2] + x * sa + z * ca) for x, y, z in c]
        quads = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 4, 7, 3), (1, 2, 6, 5), (3, 7, 6, 2), (0, 1, 5, 4)]
        for k, q in enumerate(quads):
            is_top = k == 4
            self.poly([c[i] for i in q], (top_region or region) if is_top else region, top if (is_top and top) else mat)

    def cyl(self, centre, r, length, axis, n, region, mat="Drone", cap_region=None, r2=None, top_mat=None):
        """A prism of n sides along axis 'x' or 'y' from centre, radius r (r2 at the far end)."""
        r2 = r if r2 is None else r2
        cx, cy, cz = centre
        ring0, ring1 = [], []
        for k in range(n):
            a = 2 * pi * k / n
            if axis == "x":
                ring0.append((cx, cy + r * cos(a), cz + r * sin(a)))
                ring1.append((cx + length, cy + r2 * cos(a), cz + r2 * sin(a)))
            else:
                ring0.append((cx + r * cos(a), cy, cz + r * sin(a)))
                ring1.append((cx + r2 * cos(a), cy + length, cz + r2 * sin(a)))
        for k in range(n):
            j = (k + 1) % n
            q = [ring0[k], ring0[j], ring1[j], ring1[k]]
            self.poly(q if axis == "x" else q[::-1], region, mat)
        cap = cap_region or region
        if axis == "x":
            self.poly(ring0[::-1], cap, mat)
            if r2 > 1e-4:
                self.poly(ring1, cap, mat)
        else:
            self.poly(ring0, cap, mat)
            if r2 > 1e-4:
                self.poly(ring1[::-1], cap, top_mat or mat)

    def write(self, path):
        out = ["# Generated by tools/art/build_drone_meshes.py", "mtllib drone.mtl"]
        out += ["v %.6f %.6f %.6f" % tuple(v) for v in self.v]
        out += ["vt %.6f %.6f" % tuple(t) for t in self.vt]
        out += ["vn %.6f %.6f %.6f" % tuple(n) for n in self.vn]
        for mat, faces in self.faces.items():
            out.append("usemtl " + mat)
            for f in faces:
                out.append("f " + " ".join("%d/%d/%d" % t for t in f))
        path.write_text("\n".join(out) + "\n")


def rotors(o, reach, arm_w, prop_r, z_arm, yaw0=pi / 4):
    """Four arms out from the body to motors with two-bladed props."""
    for k in range(4):
        a = yaw0 + k * pi / 2
        # Arms taped on top in the side's colour, so the side reads from above.
        o.box((0.0, -0.007, -arm_w / 2), (reach, 0.007, arm_w / 2), "carbon", yaw=-a, at=(0, z_arm, 0), top="TeamStripe", top_region="paint")
        mx, mz = reach * cos(a), reach * sin(a)
        o.cyl((mx, z_arm - 0.012, mz), 0.024, 0.03, "y", 8, "motor", cap_region="paint", top_mat="TeamStripe")
        o.cyl((mx, z_arm + 0.018, mz), 0.006, 0.012, "y", 6, "motor")
        for b in range(3):                                   # a three-bladed prop
            o.box((0.01, 0, -0.016), (prop_r, 0.004, 0.016), "prop", yaw=a * 1.7 + k + b * 2 * pi / 3, at=(mx, z_arm + 0.03, mz))


def kamikaze():
    """An FPV quad carrying an RPG warhead strapped under its belly, nose along +X."""
    o = Obj()
    o.box((-0.09, -0.02, -0.05), (0.09, 0.025, 0.05), "carbon", top="TeamStripe")      # stack
    o.box((-0.07, 0.025, -0.035), (0.06, 0.07, 0.035), "paint", top="TeamStripe")      # battery
    o.box((-0.072, 0.03, -0.037), (-0.05, 0.072, 0.037), "tape")                         # its strap
    o.box((0.075, 0.02, -0.018), (0.105, 0.05, 0.018), "camera")                        # FPV camera
    o.poly([(0.1051, 0.026, -0.008), (0.1051, 0.026, 0.008), (0.1051, 0.042, 0.008), (0.1051, 0.042, -0.008)], "lens")
    o.box((-0.1, 0.03, -0.004), (-0.09, 0.15, 0.004), "antenna", yaw=0.0)
    rotors(o, 0.2, 0.026, 0.11, 0.0)
    # The warhead: body, ogive nose, a tail tube with fins; taped on with two straps.
    o.cyl((-0.16, -0.075, 0.0), 0.042, 0.22, "x", 10, "warhead")
    o.cyl((0.06, -0.075, 0.0), 0.042, 0.06, "x", 10, "warhead", r2=0.03)
    o.cyl((0.12, -0.075, 0.0), 0.03, 0.035, "x", 10, "warhead", r2=0.0)
    o.cyl((-0.27, -0.075, 0.0), 0.014, 0.11, "x", 6, "carbon")
    for k in range(4):
        a = pi / 4 + k * pi / 2
        fy, fz = -0.075 + 0.026 * cos(a), 0.026 * sin(a)
        o.box((-0.29, fy - 0.002, fz - 0.002), (-0.22, fy + 0.002, fz + 0.002), "carbon")
    for sx in (-0.08, 0.03):
        o.box((sx, -0.12, -0.046), (sx + 0.025, -0.02, 0.046), "tape")
    return o


def scout():
    """A folding-arm reconnaissance quad in light grey with a gimbal camera under its nose."""
    o = Obj()
    o.box((-0.13, -0.035, -0.055), (0.11, 0.04, 0.055), "scout", top="TeamStripe")
    o.poly([(0.11, -0.035, -0.055), (0.11, -0.035, 0.055), (0.16, -0.015, 0.04), (0.16, -0.015, -0.04)], "scout")
    o.poly([(0.11, 0.04, 0.055), (0.11, 0.04, -0.055), (0.16, 0.02, -0.04), (0.16, 0.02, 0.04)], "scout")
    o.poly([(0.16, -0.015, -0.04), (0.16, -0.015, 0.04), (0.16, 0.02, 0.04), (0.16, 0.02, -0.04)], "vent")
    o.poly([(0.11, -0.035, 0.055), (0.11, 0.04, 0.055), (0.16, 0.02, 0.04), (0.16, -0.015, 0.04)], "scout")
    o.poly([(0.11, 0.04, -0.055), (0.11, -0.035, -0.055), (0.16, -0.015, -0.04), (0.16, 0.02, -0.04)], "scout")
    o.box((-0.14, -0.02, -0.04), (-0.13, 0.03, 0.04), "vent")
    o.box((-0.05, 0.04, -0.03), (0.06, 0.05, 0.03), "paint")                          # battery lid
    rotors(o, 0.19, 0.022, 0.1, 0.02, yaw0=radians(38))
    for z in (-0.04, 0.04):                                                           # legs
        o.box((-0.08, -0.08, z - 0.004), (0.06, -0.035, z + 0.004), "scout")
    # Gimbal: yoke and camera with its lens.
    o.box((0.09, -0.06, -0.02), (0.11, -0.035, 0.02), "camera")
    o.box((0.08, -0.1, -0.03), (0.13, -0.06, 0.03), "camera")
    o.cyl((0.13, -0.08, 0.0), 0.016, 0.012, "x", 10, "camera", cap_region="lens")
    o.box((-0.13, 0.04, -0.004), (-0.12, 0.06, 0.004), "led")
    return o


def build():
    OUT.mkdir(parents=True, exist_ok=True)
    Image.fromarray((np.clip(atlas(), 0, 1) * 255 + 0.5).astype(np.uint8), "RGB").save(OUT / "atlas.png")
    material = "Kd 1 1 1\nKs 0 0 0\nNs 0\nd 1\nillum 2\nmap_Kd atlas.png\n"
    (OUT / "drone.mtl").write_text("# Generated: the atlas, and the top plates the side's colour paints.\n"
                                   "newmtl Drone\n" + material + "\nnewmtl TeamStripe\n" + material)
    kamikaze().write(OUT / "kamikaze.obj")
    scout().write(OUT / "scout.obj")
    print("drones: kamikaze.obj, scout.obj, atlas.png written to", OUT)


if __name__ == "__main__":
    build()
