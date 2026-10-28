#!/usr/bin/env python3
"""First-person textures in the look of the SVAROG tank: realistic, weathered, pixelated.

Each picture is modelled at 8x (256 px a metre): colour, height and wear, lit from above
with occlusion and cast shadows, then averaged down to the game's 32 px a metre: a
photograph shrunk until its pixels show. Everything is periodic, so every texture tiles.
Grey surfaces keep the mean brightness of the art they replace, because models tint them.

    python3 tools/art/build_first_person.py        (numpy + PIL)
    godot --headless --editor --path . --import

Writes textures/first_person/: material_NN (FirstPersonArt.M_*), ground_NN, wall_<kind>
(4 m wide, full 2.3 m height), door_<style>, ceiling_/roof_<look>, moon and floors/fp_<floor>
(the board's floor looks, six 1 m variants each; the 2D board keeps its own).
"""
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "textures/first_person"
PX, SS = 32, 8
M = PX * SS                       # working pixels a metre
TOP = np.array([-0.32, -0.72, 0.62])   # light for walls: from above, a little left
SKY = np.array([-0.45, -0.55, 0.70])   # light for floors and tiles: the board's upper left


# --- fields ------------------------------------------------------------------------------------
def grid(h, w):
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    return (xs + 0.5) / M, (ys + 0.5) / M


def _k(h, w, sx=1.0, sy=1.0):
    fy = np.fft.fftfreq(h)[:, None] * M
    fx = np.fft.fftfreq(w)[None, :] * M
    return np.sqrt((fx * sx) ** 2 + (fy * sy) ** 2)


def noise(h, w, seed, size, sx=1.0, sy=1.0, beta=0.0):
    """Periodic noise, ~N(0, 1), features about `size` metres (size * sx along x, size * sy
    along y); beta > 0 adds finer detail falling off as 1/f^beta (a fractal)."""
    rng = np.random.default_rng(seed)
    k = _k(h, w, size * sx, size * sy)
    filt = np.exp(-k * k)
    if beta:
        filt = filt + 0.6 * np.where(k > 0, (1 + k) ** -(beta + 1), 0) * (k > 0.5)
    a = np.real(np.fft.ifft2(np.fft.fft2(rng.standard_normal((h, w))) * filt))
    return (a - a.mean()) / (a.std() + 1e-9)


def blur(a, sigma_m):
    if sigma_m <= 0:
        return a
    k = _k(a.shape[0], a.shape[1])
    f = np.exp(-2 * (np.pi * sigma_m * k) ** 2)
    return np.real(np.fft.ifft2(np.fft.fft2(a) * f)).astype(np.float32)


def hash2(a, b, seed=0):
    """A value 0..1 for each integer pair (vectorised)."""
    n = (np.asarray(a, np.int64) * 374761393 + np.asarray(b, np.int64) * 668265263 + seed * 1442695041) & 0x7FFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0x7FFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFF) / 65535.0


def sstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def mix(a, b, t):
    t = np.asarray(t, np.float32)
    if t.ndim == 2:
        t = t[..., None]
    return a * (1 - t) + b * t


def col(c, h, w):
    return np.broadcast_to(np.asarray(c, np.float32), (h, w, 3)).copy()


def rgb(hexs):
    return np.array([int(hexs[i:i + 2], 16) / 255 for i in (0, 2, 4)], np.float32)


# --- shapes on a lattice -------------------------------------------------------------------------
def cells(x, y, cw, ch, stagger=0.0, stagger_x=0.0):
    """Running-bond lattice: per pixel (u, v) inside its cell, (i, j) the cell, and d the
    distance to the cell's nearest edge (metres)."""
    j = np.floor(y / ch)
    xo = x + stagger * cw * (j % 2)
    i = np.floor(xo / cw)
    yo = y + stagger_x * ch * (i % 2)
    j = np.floor(yo / ch)
    u = xo - i * cw
    v = yo - j * ch
    d = np.minimum(np.minimum(u, cw - u), np.minimum(v, ch - v))
    return u, v, i, j, d


def bevel(d, joint, round_m):
    """Height 0 in a joint of half-width `joint`, rising over `round_m` to 1."""
    return sstep(joint, joint + round_m, d)


# --- light and down-sampling -----------------------------------------------------------------------
def shade(c, hgt, light=TOP, relief=1.0, ao=1.0, amb=0.5, cast=0.6, gloss=0.0):
    """Light colour c (h, w, 3) on height map hgt (metres), periodic at the edges."""
    L = light / np.linalg.norm(light)
    gx = (np.roll(hgt, -1, 1) - np.roll(hgt, 1, 1)) * M * 0.5 * relief
    gy = (np.roll(hgt, -1, 0) - np.roll(hgt, 1, 0)) * M * 0.5 * relief
    nz = 1 / np.sqrt(gx * gx + gy * gy + 1)
    diff = np.clip((-gx * L[0] - gy * L[1] + L[2]) * nz, 0, 1)
    s = (amb + (1 - amb) * diff) / (amb + (1 - amb) * L[2])
    if gloss:
        hv = (L + np.array([0, 0, 1.0]))
        hv /= np.linalg.norm(hv)
        s = s + gloss * np.clip((-gx * hv[0] - gy * hv[1] + hv[2]) * nz, 0, 1) ** 30
    occ = np.clip((blur(hgt, 0.035) - hgt) * 18 + (blur(hgt, 0.12) - hgt) * 6, 0, 0.65) * ao
    sh = np.zeros_like(hgt)
    if cast:
        dx, dy = -L[0] / L[2], -L[1] / L[2]
        for step in (0.006, 0.012, 0.02, 0.032, 0.05):
            o = np.roll(np.roll(hgt, int(round(dy * step * M)), 0), int(round(dx * step * M)), 1)
            sh = np.maximum(sh, np.clip((o - hgt - step) * 60, 0, 1))
        sh = blur(sh, 0.004) * cast
    k = s * (1 - occ) * (1 - sh)
    return c * k[..., None]


def down(a):
    """Average SS x SS blocks (the photo shrunk), then a light periodic sharpen."""
    h, w = a.shape[0] // SS, a.shape[1] // SS
    s = a.reshape(h, SS, w, SS, -1).mean(axis=(1, 3))
    soft = (np.roll(s, 1, 0) + np.roll(s, -1, 0) + np.roll(s, 1, 1) + np.roll(s, -1, 1)) / 4
    return np.clip(s + 0.2 * (s - soft), 0, 1)


def lum(a):
    return a[..., 0] * 0.3 + a[..., 1] * 0.59 + a[..., 2] * 0.11


def match(a, target):
    """Scale to a mean brightness (alpha-weighted where there is alpha)."""
    rgbv = a[..., :3]
    w = a[..., 3] if a.shape[-1] == 4 else np.ones(a.shape[:2])
    m = (lum(rgbv) * w).sum() / max(w.sum(), 1e-6)
    out = a.copy()
    out[..., :3] = np.clip(rgbv * (target / max(m, 1e-6)), 0, 1)
    return out


def save(a, name):
    path = OUT / name
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = "RGBA" if a.shape[-1] == 4 else "RGB"
    if mode == "RGB":
        a = np.concatenate([a, np.ones(a.shape[:2] + (1,), np.float32)], -1)
        mode = "RGBA"
    Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8), mode).save(path)


def old_mean(name):
    """Mean brightness of a shipped picture (what models were tuned against)."""
    p = OUT / name
    if not p.exists():
        return None
    a = np.asarray(Image.open(p).convert("RGBA")).astype(np.float32) / 255
    w = a[..., 3]
    return float((lum(a[..., :3]) * w).sum() / max(w.sum(), 1e-6))


# --- weathering ----------------------------------------------------------------------------------------
def grime(h, w, seed, size=0.35, amount=0.25, bias=0.0):
    """Multiplicative dirt: soft blotches at two scales."""
    g = noise(h, w, seed, size * 2, beta=0.8) * 0.75 + noise(h, w, seed + 1, size * 0.4) * 0.25
    return 1 - amount * 0.6 * sstep(0.2 + bias, 2.4 + bias, g)


def streaks(h, w, seed, length=0.6, width=0.012, amount=0.25):
    """Run-down stains: thin along x, long along y, starting at random heights."""
    s = noise(h, w, seed, width, sy=length / width)
    start = noise(h, w, seed + 7, length * 0.5) > 0.3
    return 1 - amount * sstep(0.4, 2.2, s) * (0.4 + 0.6 * start)


def scratches(h, w, seed, n, length=0.08, light=0.25):
    x, y = grid(h, w)
    out = np.zeros((h, w), np.float32)
    rng = np.random.default_rng(seed)
    W, H = w / M, h / M
    for _ in range(n):
        x0, y0 = rng.random() * W, rng.random() * H
        a = rng.random() * np.pi
        L = length * (0.4 + rng.random())
        dx, dy = np.cos(a) * L, np.sin(a) * L
        px = (x - x0 + W / 2) % W - W / 2
        py = (y - y0 + H / 2) % H - H / 2
        t = np.clip((px * dx + py * dy) / (L * L), 0, 1)
        d = np.hypot(px - t * dx, py - t * dy)
        out = np.maximum(out, np.clip(1 - d / 0.0025, 0, 1) * (0.5 + 0.5 * rng.random()))
    return out * light


def specks(h, w, seed, density, size=0.004):
    """Little dots (pores, grit): a mask 0..1."""
    rng = np.random.default_rng(seed)
    m = (rng.random((h, w)) < density).astype(np.float32)
    return np.clip(blur(m, size) * (2 * np.pi * (size * M) ** 2), 0, 1)


# --- walls: 4 m wide, 2.3 m tall; y = 0 is the top, the last row the floor ---------------------------
WALL_W, WALL_H = 128, 74


def wall_canvas():
    h, w = WALL_H * SS, WALL_W * SS
    x, y = grid(h, w)
    return h, w, x, h / M - y          # x along the wall, f = height above the floor


def floor_dirt(h, w, f, seed, height=0.45, amount=0.3):
    """Scuffs, splashes and damp gathering toward the floor."""
    n = noise(h, w, seed, 0.06, beta=1.0)
    return 1 - amount * sstep(height, 0.0, f + 0.08 * n)


def w_brick():
    h, w, x, f = wall_canvas()
    u, v, i, j, d = cells(x, f, 0.25, 3 / PX, stagger=0.5)
    b = bevel(d, 0.005, 0.007)
    tone = hash2(i, j, 11)
    brick = mix(rgb("6e2c1e"), rgb("a24f33"), tone)
    brick = mix(brick, rgb("3a1d16"), (hash2(i, j, 12) > 0.9) * 0.6)          # over-fired
    brick = mix(brick, rgb("b7865c"), (hash2(i, j, 13) > 0.94) * 0.5)          # a pale one
    brick *= (1 + 0.1 * noise(h, w, 14, 0.01))[..., None]
    pits = specks(h, w, 15, 0.003, 0.003)
    mortar = col(rgb("8d877c"), h, w) * (1 + 0.08 * noise(h, w, 16, 0.004))[..., None]
    c = mix(mortar, brick, b) * (1 - 0.35 * pits)[..., None]
    chip = (noise(h, w, 17, 0.012) > 2.2) * b
    hgt = b * 0.012 - pits * 0.002 - chip * 0.006
    c = mix(c, rgb("c7c0b0"), sstep(0.5, 2.5, noise(h, w, 18, 0.08)) * sstep(0.7, 0.1, f) * 0.5)  # saltpetre
    c = shade(c, hgt, relief=0.9)
    k = grime(h, w, 19, 0.5, 0.28) * streaks(h, w, 20, 0.8, 0.02, 0.2) * floor_dirt(h, w, f, 21, 0.4, 0.3)
    return c * k[..., None]


def w_stucco():
    h, w, x, f = wall_canvas()
    plinth = f < 0.28
    u, v, i, j, d = cells(x, f, 0.5, 0.14, stagger=0.5)
    stone = mix(rgb("6f6a62"), rgb("8a847a"), hash2(i, j, 31)) * (1 + 0.12 * noise(h, w, 32, 0.02, beta=1))[..., None]
    sb = bevel(d, 0.006, 0.02)
    render = col(rgb("cfc4ad"), h, w) * (1 + 0.05 * noise(h, w, 33, 0.3, beta=1.4))[..., None]
    render *= (1 + 0.05 * noise(h, w, 34, 0.004))[..., None]
    # Patched render: smoother, a shade greyer, standing a little proud.
    patch = sstep(1.3, 1.5, noise(h, w, 35, 0.3)) * (f > 0.35)
    c = mix(render, render * np.array([0.93, 0.94, 0.97]), patch)
    hgt = 0.002 * patch + 0.002 * noise(h, w, 37, 0.01) * (1 - 0.6 * patch)
    crack = np.abs(noise(h, w, 38, 0.25, beta=1.6)) < 0.025
    crack = crack * (noise(h, w, 39, 0.4) > 0.3)
    hgt -= crack * 0.004
    c = mix(c, rgb("4a4238"), crack * 0.7)
    band = (f >= 0.28) & (f < 0.31)
    c = np.where(plinth[..., None], mix(rgb("3e3a35"), stone, sb), c)
    c = np.where(band[..., None], col(rgb("55514b"), h, w), c)
    hgt = np.where(plinth, 0.02 * sb, hgt)
    hgt = np.where(band, 0.025, hgt)
    c = shade(c, hgt, relief=0.8)
    k = grime(h, w, 40, 0.6, 0.22) * streaks(h, w, 41, 1.2, 0.03, 0.3) * floor_dirt(h, w, f, 42, 0.6, 0.35)
    return c * k[..., None]


def w_block():
    h, w, x, f = wall_canvas()
    u, v, i, j, d = cells(x, f, 0.4, 0.2, stagger=0.5)
    b = bevel(d, 0.006, 0.01)
    face = mix(rgb("85837d"), rgb("a19e96"), hash2(i, j, 51))
    face = face * (1 + 0.1 * noise(h, w, 52, 0.006))[..., None] * (1 + 0.06 * noise(h, w, 53, 0.08))[..., None]
    pores = specks(h, w, 54, 0.006, 0.0025)
    c = mix(col(rgb("6f6c66"), h, w), face, b) * (1 - 0.4 * pores)[..., None]
    hgt = b * 0.01 - pores * 0.003 - (noise(h, w, 55, 0.015) > 2.3) * b * 0.008
    c = shade(c, hgt, relief=0.9)
    k = grime(h, w, 56, 0.45, 0.25) * streaks(h, w, 57, 0.9, 0.025, 0.25) * floor_dirt(h, w, f, 58, 0.5, 0.35)
    return c * k[..., None]


def hull_panels(h, w, x, f, paint, seed, heavy=False):
    """Bolted panels with a kick plate, a cable tray, vents, a hatch and stencils."""
    kick = f < 0.2
    trim = f > 2.2
    seam_x = np.minimum(x % 1.0, 1.0 - x % 1.0)
    seam_y = np.abs(f - 1.25)
    body = bevel(np.minimum(seam_x, np.where(f > 1.25, np.minimum(seam_y, 2.2 - f), np.minimum(seam_y, f - 0.2))), 0.004, 0.012)
    panel = np.floor(x)
    tone = 1 + 0.035 * (hash2(panel, f > 1.25, seed) - 0.5)
    c = col(paint, h, w) * tone[..., None] * (1 + 0.04 * noise(h, w, seed + 1, 0.25, beta=1))[..., None]
    c = mix(c * 0.42, c, sstep(0.0, 0.6, body))
    hgt = 0.006 * body
    # Bolts at every panel's corners.
    for bx in (0.05, 0.95):
        for by in (0.27, 1.18, 1.32, 2.13):
            r = np.hypot((x % 1.0) - bx, f - by)
            bolt = sstep(0.011, 0.006, r)
            hgt = hgt + bolt * 0.006
            c = mix(c, c * 0.8, bolt * 0.5)
            c = mix(c, rgb("6b4a35"), sstep(0.02, 0.006, r) * sstep(0.0, -0.08, f - by) * 0.0 + bolt * 0.15)
    # A louvred vent low in panel 1, a hatch in panel 2, stencils in panel 3.
    lx, inp = x % 1.0, panel
    vent = (inp == 1) & (lx > 0.55) & (lx < 0.85) & (f > 0.35) & (f < 0.6)
    slat = ((f - 0.35) * 40) % 1.0
    c = np.where(vent[..., None], c * (0.35 + 0.65 * sstep(0.2, 0.6, slat))[..., None], c)
    hgt = np.where(vent, hgt - 0.006 + 0.004 * slat, hgt)
    hatch = (inp == 2) & (lx > 0.18) & (lx < 0.62) & (f > 0.45) & (f < 1.05)
    hd = np.minimum(np.minimum(lx - 0.18, 0.62 - lx), np.minimum(f - 0.45, 1.05 - f))
    hgt = hgt + hatch * (bevel(hd, 0.0, 0.006) * 0.004 - 0.002)
    handle = (inp == 2) & (np.abs(lx - 0.56) < 0.012) & (np.abs(f - 0.75) < 0.06)
    hgt = hgt + handle * 0.012
    c = np.where(handle[..., None], col(rgb("2b2b2b"), h, w), c)
    sten = (inp == 3) & (lx > 0.12) & (lx < 0.5) & (f > 1.55) & (f < 1.62)
    letters = hash2(np.floor((lx - 0.12) / 0.035), np.floor((f - 1.55) / 0.035), seed + 3) > 0.35
    gaps = ((lx - 0.12) % 0.035) > 0.007
    c = mix(c, rgb("1d1f22"), (sten & letters & gaps) * 0.75)
    label = (inp == 3) & (lx > 0.12) & (lx < 0.32) & (f > 1.42) & (f < 1.5)
    stripe = (((lx + f) / 0.03) % 2) < 1
    c = np.where(label[..., None], np.where(stripe[..., None], col(rgb("c79a1c"), h, w), col(rgb("1f1d1a"), h, w)), c)
    # A cable tray along the top, on brackets.
    tray = (f > 1.9) & (f < 2.0)
    c = np.where(tray[..., None], col(rgb("4c4f52"), h, w) * (0.85 + 0.15 * ((f - 1.9) / 0.1))[..., None], c)
    hgt = np.where(tray, 0.03 + 0.01 * np.sin((f - 1.9) / 0.1 * np.pi), hgt)
    for k2, cc in enumerate(("2d5a8a", "8a2d2d", "2d6b3a")):
        cab = (np.abs(f - (1.925 + 0.025 * k2)) < 0.008) & ~((x % 0.5) < 0.02)
        c = np.where(cab[..., None], col(rgb(cc), h, w) * 0.8, c)
        hgt = np.where(cab, 0.035 + 0.008, hgt)
    # Kick plate: dark ribbed steel; heavy walls get a worn hazard stripe.
    kp = col(rgb("2f3133"), h, w) * (1 + 0.15 * noise(h, w, seed + 5, 0.01))[..., None]
    if heavy:
        hz = (((x + f) / 0.1) % 2) < 1
        kp = np.where(hz[..., None], col(rgb("b88a1a"), h, w), col(rgb("1c1c1c"), h, w))
        kp = mix(kp, rgb("4a4640"), sstep(0.3, 1.8, noise(h, w, seed + 6, 0.04, beta=1)) * 0.8)
    c = np.where(kick[..., None], kp, c)
    hgt = np.where(kick, 0.012 + 0.002 * (((x * 30) % 1) > 0.5), hgt)
    c = np.where(trim[..., None], col(paint * 0.55, h, w), c)
    hgt = np.where(trim, 0.015, hgt)
    # Wear: scuffs at boot and cart height, scratches showing bare metal.
    scuff = sstep(0.8, 2.2, noise(h, w, seed + 7, 0.05, sy=0.4)) * sstep(1.1, 0.25, f) * (f > 0.2)
    c = mix(c, c * 0.6, scuff * 0.6)
    c = c + scratches(h, w, seed + 8, 120, 0.06, 0.18)[..., None]
    c = shade(c, hgt, relief=0.8, gloss=0.08)
    k = grime(h, w, seed + 9, 0.6, 0.18) * streaks(h, w, seed + 10, 0.5, 0.01, 0.18) * floor_dirt(h, w, f, seed + 11, 0.35, 0.25)
    return c * k[..., None]


def w_station():
    h, w, x, f = wall_canvas()
    return hull_panels(h, w, x, f, rgb("aeb2b3"), 60)


def w_bunker():
    h, w, x, f = wall_canvas()
    # Painted dado to 1.2 m, bare board-formed concrete above, a hazard stripe at the foot.
    conc = concrete(h, w, x, f, 70)
    dado = f < 1.2
    paint = col(rgb("6d7a6a"), h, w) * (1 + 0.05 * noise(h, w, 71, 0.3, beta=1))[..., None]
    peel = sstep(1.6, 2.0, noise(h, w, 72, 0.06, beta=1.2))
    c = np.where(dado[..., None], mix(paint, conc[0], peel), conc[0])
    hgt = np.where(dado, conc[1] + 0.003 * (1 - peel), conc[1])
    rail = np.abs(f - 1.21) < 0.02
    c = np.where(rail[..., None], col(rgb("3c3f40"), h, w), c)
    hgt = np.where(rail, 0.02, hgt)
    foot = f < 0.15
    hz = (((x + f) / 0.1) % 2) < 1
    hzc = np.where(hz[..., None], col(rgb("b48a1d"), h, w), col(rgb("1e1d1b"), h, w))
    hzc = mix(hzc, conc[0] * 0.8, sstep(0.6, 2.0, noise(h, w, 73, 0.04, beta=1)) * 0.85)
    c = np.where(foot[..., None], hzc, c)
    c = shade(c, hgt, relief=0.8)
    k = grime(h, w, 74, 0.6, 0.25) * streaks(h, w, 75, 0.9, 0.02, 0.3) * floor_dirt(h, w, f, 76, 0.4, 0.3)
    return c * k[..., None]


def concrete(h, w, x, f, seed, boards=True):
    """Board-formed concrete: plank imprints 15 cm high, tie holes, honeycombing."""
    c = col(rgb("8e8b84"), h, w) * (1 + 0.04 * noise(h, w, seed, 0.6, beta=0.8))[..., None]
    hgt = 0.002 * noise(h, w, seed + 1, 0.008)
    if boards:
        row = np.floor(f / 0.15)
        c *= (1 + 0.09 * (hash2(row, 0, seed + 2) - 0.5))[..., None]
        grain = noise(h, w, seed + 3, 0.008, sx=12)
        c *= (1 + 0.035 * grain)[..., None]
        line = sstep(0.006, 0.0, np.minimum(f % 0.15, 0.15 - f % 0.15))
        c = mix(c, c * 0.62, line)
        hgt += line * 0.002
        tie = np.hypot((x % 0.6) - 0.3, (f % 0.6) - 0.3) < 0.012
        c = mix(c, rgb("3b3935"), tie * 0.9)
        hgt -= tie * 0.008
    pores = specks(h, w, seed + 4, 0.004, 0.003)
    honey = sstep(1.8, 2.4, noise(h, w, seed + 5, 0.05))
    c *= (1 - 0.4 * pores - 0.25 * honey)[..., None]
    hgt -= pores * 0.003 + honey * 0.004
    return c, hgt


def w_dot(slit=False):
    h, w, x, f = wall_canvas()
    c, hgt = concrete(h, w, x, f, 80)
    if slit:
        lx = x % 1.0
        s = (f > 1.06) & (f < 1.25) & (lx > 0.1) & (lx < 0.88)
        dd = np.minimum(np.minimum(lx - 0.1, 0.88 - lx), np.minimum(f - 1.06, 1.25 - f))
        depth = sstep(0.0, 0.03, dd)
        c = np.where(s[..., None], c * (0.12 + 0.5 * (1 - depth))[..., None], c)
        hgt = np.where(s, -0.06 * depth, hgt)
    c = shade(c, hgt, relief=0.9)
    k = grime(h, w, 81, 0.5, 0.3) * streaks(h, w, 82, 1.0, 0.025, 0.35) * floor_dirt(h, w, f, 83, 0.4, 0.3)
    return c * k[..., None]


def w_armor():
    h, w, x, f = wall_canvas()
    u, v, i, j, d = cells(x, f, 1.0, 2.3 / 3, stagger=0.5)
    b = bevel(d, 0.006, 0.015)
    steel = col(rgb("4a4d4f"), h, w) * (1 + 0.08 * noise(h, w, 90, 0.2, beta=1.2))[..., None]
    steel *= (1 + 0.06 * (hash2(i, j, 91) - 0.5))[..., None]
    weld = sstep(0.012, 0.004, d) * (1 + 0.5 * np.sin(np.where(np.abs(u - 0.5) < 0.49, u, v) * 900))
    c = mix(col(rgb("2a2b2c"), h, w), steel, b)
    c = mix(c, rgb("5a5550"), np.clip(weld, 0, 1) * 0.5)
    hgt = b * 0.012 + np.clip(weld, 0, 1) * 0.003
    for bx in (0.07, 0.5, 0.93):
        for by in (0.07, 2.3 / 3 - 0.07):
            r = np.hypot(u - bx, v - by)
            bolt = sstep(0.022, 0.014, r)
            hgt = hgt + bolt * 0.018 * sstep(0.022, 0.0, r)
            rust = sstep(0.05, 0.0, np.hypot((u - bx) * 3, np.clip(v - by, -1, 0) * 0.5 + (v - by) * 0.2)) * (v < by + 0.02)
            c = mix(c, rgb("6b3d22"), rust * 0.35)
    c = mix(c, rgb("1b1a19"), sstep(1.2, 2.4, noise(h, w, 92, 0.25, beta=1.2)) * 0.6)    # scorch
    c = c + scratches(h, w, 93, 220, 0.08, 0.22)[..., None]
    c = mix(c, rgb("6a3a20"), sstep(1.6, 2.6, noise(h, w, 94, 0.05, beta=1)) * 0.6)          # rust
    c = shade(c, hgt, relief=0.8, gloss=0.12)
    k = streaks(h, w, 95, 0.6, 0.01, 0.3) * floor_dirt(h, w, f, 96, 0.4, 0.25)
    return c * k[..., None]


def w_wood():
    h, w, x, f = wall_canvas()
    pw = 0.16
    i = np.floor(x / pw)
    u = x - i * pw
    gap = sstep(0.004, 0.0, np.minimum(u, pw - u))
    tone = hash2(i, 0, 101)
    base = mix(rgb("6b5039"), rgb("8a7258"), tone)
    base = mix(base, rgb("7e7b74"), sstep(0.3, 1.8, noise(h, w, 102, 0.4)) * 0.5)        # silvered
    grain = noise(h, w, 103, 0.004, sy=14) + 0.5 * noise(h, w, 104, 0.015, sy=8)
    c = base[None, None, :] * (1 + 0.12 * grain)[..., None] if base.ndim == 1 else base * (1 + 0.12 * grain)[..., None]
    kx = (i + 0.5) * pw
    for s in range(3):
        ky = hash2(i, s, 105) * 2.3
        knot = np.hypot((x - kx) * 3, f - ky) < 0.02
        c = mix(c, rgb("3a2a1c"), knot * (hash2(i, s, 106) > 0.6) * 0.8)
    c = mix(c, rgb("1a120c"), gap)
    hgt = (1 - gap) * 0.006 + 0.0015 * grain
    for ny in (0.25, 2.05):
        nail = (np.hypot(u - pw / 2, f - ny) < 0.006)
        c = mix(c, rgb("2e2a26"), nail * 0.9)
        hgt += nail * 0.002
        c = mix(c, rgb("5a3a24"), sstep(0.03, 0.0, np.hypot(u - pw / 2, np.clip(ny - f, 0, 1) * 0.3)) * (f < ny) * 0.3)
    c = shade(c, hgt, relief=1.0)
    k = grime(h, w, 107, 0.5, 0.2) * floor_dirt(h, w, f, 108, 0.35, 0.3)
    return c * k[..., None]


def earth(h, w, x, f, seed, rock=False):
    strata = noise(h, w, seed, 0.03, sx=12)
    if rock:
        base = mix(rgb("4d4a47"), rgb("7a746c"), sstep(-1.5, 1.5, strata + 0.6 * noise(h, w, seed + 1, 0.2, beta=1.5)))
        hgt = 0.05 * noise(h, w, seed + 2, 0.12, beta=1.6) + 0.01 * strata
        crack = (np.abs(noise(h, w, seed + 3, 0.3, beta=1.7)) < 0.03)
        hgt -= crack * 0.02
        base = mix(base, rgb("201e1c"), crack * 0.8)
        return base, hgt
    base = mix(rgb("4f3a28"), rgb("6e5640"), sstep(-1.5, 1.5, strata))
    base = base * (1 + 0.12 * noise(h, w, seed + 4, 0.01))[..., None]
    hgt = 0.01 * noise(h, w, seed + 5, 0.05, beta=1.4)
    stones = sstep(1.9, 2.3, noise(h, w, seed + 6, 0.025))
    sc = mix(rgb("7f7a72"), rgb("9b958b"), hash2(np.floor(x * 30), np.floor(f * 30), seed + 7))
    base = mix(base, sc, stones)
    hgt += stones * 0.015
    root = (np.abs(noise(h, w, seed + 8, 0.06, sy=0.5)) < 0.04) & (noise(h, w, seed + 9, 0.3) > 0.6)
    base = mix(base, rgb("2c2016"), root * 0.8)
    hgt += root * 0.004
    return base, hgt


def w_soil():
    h, w, x, f = wall_canvas()
    c, hgt = earth(h, w, x, f, 110)
    c = shade(c, hgt, relief=1.0)
    k = grime(h, w, 111, 0.4, 0.2) * floor_dirt(h, w, f, 112, 0.5, 0.25)
    return c * k[..., None]


def w_rock():
    h, w, x, f = wall_canvas()
    c, hgt = earth(h, w, x, f, 120, rock=True)
    return shade(c, hgt, relief=1.2, cast=0.8)


def bags(h, w, x, f, seed, bag_w=0.5, bag_h=0.13):
    """Rows of filled bags, each with its own bulge, seam and tied end."""
    row = np.floor(f / bag_h)
    xo = x + (row % 2) * bag_w * 0.5 + (hash2(row, 0, seed) - 0.5) * 0.1
    i = np.floor(xo / bag_w)
    u = (xo - i * bag_w) / bag_w
    v = (f - row * bag_h) / bag_h
    sag = 0.08 * (hash2(i, row, seed + 1) - 0.5)
    bul = np.clip(1 - ((u - 0.5) / 0.52) ** 4, 0, 1) * np.clip(1 - ((v - 0.5 - sag) / 0.56) ** 2, 0, 1)
    tone = hash2(i, row, seed + 2)
    cloth = mix(rgb("7b6e50"), rgb("a29571"), tone)
    cloth = mix(cloth, rgb("5d5a43"), (hash2(i, row, seed + 3) > 0.8) * 0.6)
    weave = noise(h, w, seed + 4, 0.003) * 0.06 + noise(h, w, seed + 5, 0.03) * 0.05
    c = cloth * (1 + weave)[..., None]
    c = mix(c, rgb("4a3a26"), sstep(0.8, 2.0, noise(h, w, seed + 6, 0.06)) * 0.5)          # mud
    seam = (np.abs(v - 0.5 - sag) < 0.02) * (bul > 0.2)
    c = mix(c, c * 0.7, seam)
    c = mix(c * 0.35, c, sstep(0.0, 0.25, bul))
    hgt = 0.1 * np.sqrt(bul) - seam * 0.004
    return c, hgt


def w_sandbag():
    h, w, x, f = wall_canvas()
    c, hgt = bags(h, w, x, f, 130)
    c = shade(c, hgt, relief=0.8, cast=0.9)
    return c * floor_dirt(h, w, f, 131, 0.3, 0.2)[..., None]


def w_corpse():
    h, w, x, f = wall_canvas()
    lumps = noise(h, w, 140, 0.12, beta=1.0)
    region = np.floor((noise(h, w, 141, 0.15) + 3) * 1.5)
    palette = np.array([rgb("3b3a2c"), rgb("4a4436"), rgb("2c2a28"), rgb("5a4a3a"), rgb("3a3f45"), rgb("6b5a48")])
    c = palette[(region.astype(int)) % len(palette)] * (1 + 0.1 * noise(h, w, 142, 0.01))[..., None]
    blood = sstep(0.7, 1.8, noise(h, w, 143, 0.08, beta=1.2))
    c = mix(c, rgb("4a0e0b"), blood * 0.8)
    hgt = 0.06 * lumps
    return shade(c, hgt, relief=1.0, cast=0.9)


def w_ldf():
    """The deployable barrier: matt black composite modules 1 m wide in three bevelled
    panels, recessed bolts, white stencil ticks worn thin, dust and scuffs."""
    h, w, x, f = wall_canvas()
    u, v, i, j, d = cells(x, f, 1.0, 2.3 / 3)
    b = bevel(d, 0.006, 0.035)
    c = col(rgb("16171a"), h, w) * (1 + 0.12 * noise(h, w, 150, 0.3) + 0.06 * noise(h, w, 151, 0.02))[..., None]
    c *= (1 + 0.08 * (hash2(i, j, 152) - 0.5))[..., None]
    c = mix(c * 0.4, c, sstep(0.0, 0.5, b))
    rim = sstep(0.04, 0.012, d) * (d > 0.006)
    c = mix(c, rgb("3b3d42"), rim * sstep(0.5, 0.0, np.minimum(u, v)) * 0.0 + rim * 0.35)
    hgt = 0.02 * b
    for bx in (0.06, 0.94):
        for by in (0.06, 2.3 / 3 - 0.06):
            r = np.hypot(u - bx, v - by)
            hgt = hgt - sstep(0.016, 0.01, r) * 0.006
            c = mix(c, rgb("2c2e32"), sstep(0.016, 0.01, r) * 0.8)
    tick = (np.abs(u - 0.78) < 0.012) & (v > 0.26) & (v < 0.43)
    c = mix(c, rgb("c9cbcf"), tick * sstep(-1.2, 0.4, noise(h, w, 153, 0.02)) * 0.85)
    dust = sstep(0.9, 0.0, f + 0.15 * noise(h, w, 154, 0.08)) * 0.5 + sstep(1.2, 2.4, noise(h, w, 155, 0.25)) * 0.25
    c = mix(c, rgb("57534b"), np.clip(dust, 0, 1) * 0.6)
    c = c + scratches(h, w, 156, 160, 0.07, 0.22)[..., None]
    c = shade(c, hgt, relief=0.8, gloss=0.05)
    return c * floor_dirt(h, w, f, 157, 0.3, 0.2)[..., None]


WALLS = {"brick": w_brick, "stucco": w_stucco, "block": w_block, "station": w_station,
         "bunker": w_bunker, "armor": w_armor, "dot": w_dot, "dot_open": lambda: w_dot(True),
         "wood": w_wood, "soil": w_soil, "rock": w_rock, "sandbag": w_sandbag, "corpse": w_corpse,
         "ldf": w_ldf}
# Wall surfaces as model materials after the M_* tiles (FirstPersonArt.WALL_MATS): a 1 m
# piece from hand height, so a wall's chunks and rubble wear the wall they came from.
WALL_MATS = ["brick", "stucco", "block", "station", "bunker", "armor", "dot", "wood", "soil",
             "rock", "sandbag", "corpse", "ldf"]


# --- model materials: 1 m tiles, FirstPersonArt.M_* order -------------------------------------------
def tile_canvas(metres=1.0):
    h = w = int(round(metres * M))
    x, y = grid(h, w)
    return h, w, x, y


def grey(v, h, w):
    return col((v, v, v), h, w)


def m_plain():
    h, w, x, y = tile_canvas()
    c = grey(0.9, h, w) * (1 + 0.03 * noise(h, w, 201, 0.4, beta=0.8) + 0.02 * noise(h, w, 202, 0.006))[..., None]
    c = c * grime(h, w, 203, 0.4, 0.12)[..., None] - scratches(h, w, 204, 12, 0.05, 0.08)[..., None]
    return shade(c, 0.0008 * noise(h, w, 205, 0.01), SKY)


def m_wood():
    h, w, x, y = tile_canvas()
    figure = noise(h, w, 211, 0.03, sx=10, beta=0.5)
    rings = np.sin((y + 0.02 * noise(h, w, 212, 0.08, sx=6)) * 2 * np.pi * 22 + figure * 2.5)
    pores = noise(h, w, 213, 0.002, sx=20)
    v = 0.84 + 0.07 * rings + 0.04 * figure + 0.03 * pores
    c = grey(1, h, w) * v[..., None] * np.array([1.0, 0.97, 0.93])
    c = c * (1 - 0.06 * sstep(0.5, 2.0, noise(h, w, 214, 0.15)))[..., None] + scratches(h, w, 215, 20, 0.06, 0.06)[..., None]
    return shade(c, 0.0006 * rings, SKY, gloss=0.05)


def m_metal():
    h, w, x, y = tile_canvas()
    brush = noise(h, w, 221, 0.002, sx=60) * 0.04 + noise(h, w, 222, 0.05, beta=0.8) * 0.04
    c = grey(0.85, h, w) * (1 + brush)[..., None]
    c = c + scratches(h, w, 223, 40, 0.05, 0.12)[..., None]
    c = c * grime(h, w, 224, 0.3, 0.15)[..., None]
    return shade(c, np.zeros((h, w), np.float32), SKY, gloss=0.1)


def m_plate():
    h, w, x, y = tile_canvas()
    u, v, i, j, d = cells(x, y, 0.5, 0.5)
    b = bevel(d, 0.004, 0.01)
    c = grey(0.86, h, w) * (1 + 0.04 * noise(h, w, 231, 0.2, beta=1) + 0.03 * (hash2(i, j, 232) - 0.5))[..., None]
    c = mix(c * 0.5, c, b)
    hgt = 0.006 * b
    for bx in (0.06, 0.44):
        for by in (0.06, 0.44):
            r = np.hypot(u - bx, v - by)
            hgt += sstep(0.012, 0.006, r) * 0.006
    c = mix(c, c * np.array([0.85, 0.7, 0.55]), sstep(0.02, 0.0, d) * 0.4)          # rust in the seams
    c = c + scratches(h, w, 233, 30, 0.05, 0.1)[..., None]
    return shade(c, hgt, SKY, gloss=0.08) * grime(h, w, 234, 0.3, 0.15)[..., None]


def m_fabric():
    h, w, x, y = tile_canvas()
    wr = noise(h, w, 241, 0.05, sx=0.4, beta=0.6)
    weave = 0.0
    c = grey(0.86, h, w) * (1 + 0.02 * noise(h, w, 242, 0.03) + weave + 0.04 * noise(h, w, 243, 0.3))[..., None]
    c = c * (1 - 0.08 * specks(h, w, 244, 0.004, 0.003))[..., None]
    c = c * grime(h, w, 245, 0.3, 0.12)[..., None]
    return shade(c, 0.006 * wr, SKY, relief=1.0, cast=0.2)


def m_plastic():
    h, w, x, y = tile_canvas()
    c = grey(0.92, h, w) * (1 + 0.02 * noise(h, w, 251, 0.3) + 0.01 * noise(h, w, 252, 0.004))[..., None]
    c = c - scratches(h, w, 253, 25, 0.04, 0.06)[..., None] * 0.6
    return shade(c * grime(h, w, 254, 0.3, 0.1)[..., None], np.zeros((h, w), np.float32), SKY, gloss=0.15)


def m_ceramic():
    h, w, x, y = tile_canvas()
    craze = (np.abs(noise(h, w, 261, 0.06, beta=1.4)) < 0.02).astype(np.float32)
    c = grey(0.96, h, w) * (1 + 0.012 * noise(h, w, 262, 0.2))[..., None] * (1 - 0.06 * craze)[..., None]
    return shade(c * grime(h, w, 263, 0.25, 0.08)[..., None], np.zeros((h, w), np.float32), SKY, gloss=0.3)


def m_leaves():
    """Overlapping leaves, each a little dome lit on its upper side; gaps in shadow."""
    h, w, x, y = tile_canvas()
    rng = np.random.default_rng(271)
    hgt = np.full((h, w), -0.04, np.float32)
    tone = np.zeros((h, w), np.float32)
    for k in range(260):
        cx, cy, a = rng.random(), rng.random(), rng.random() * np.pi
        L, W = 0.08 + rng.random() * 0.06, 0.035 + rng.random() * 0.02
        px = (x - cx + 0.5) % 1.0 - 0.5
        py = (y - cy + 0.5) % 1.0 - 0.5
        u = px * np.cos(a) + py * np.sin(a)
        v = -px * np.sin(a) + py * np.cos(a)
        r = (u / L) ** 2 + (v / W) ** 2
        z = rng.random() * 0.04 + 0.01 * np.sqrt(np.clip(1 - r, 0, 1))
        on = (r < 1) & (z > hgt)
        hgt = np.where(on, z, hgt)
        tone = np.where(on, rng.random() * 0.3 + 0.55 * (1 - 0.3 * np.abs(v / W)), tone)
    c = grey(1, h, w) * np.where(hgt > -0.03, 0.62 + 0.3 * tone, 0.32)[..., None]
    return shade(c, hgt, SKY, relief=0.6, cast=0.8)


def m_bark():
    h, w, x, y = tile_canvas()
    ridges = noise(h, w, 281, 0.03, sy=5, beta=0.3)
    c = grey(0.68, h, w) * (1 + 0.12 * ridges + 0.03 * noise(h, w, 282, 0.03))[..., None]
    c = mix(c, c * 0.35, sstep(-0.6, -1.4, ridges))
    moss = sstep(1.0, 2.0, noise(h, w, 283, 0.1))
    c = mix(c, c * np.array([0.8, 1.0, 0.7]), moss * 0.5)
    return shade(c, 0.012 * ridges, SKY, relief=1.0, cast=0.7)


def m_burlap():
    h, w, x, y = tile_canvas()
    th = noise(h, w, 290, 0.03)
    c = grey(0.82, h, w) * (1 + 0.04 * th + 0.06 * noise(h, w, 292, 0.15))[..., None]
    c = c * grime(h, w, 293, 0.2, 0.3)[..., None]
    return shade(c, 0.002 * th + 0.004 * noise(h, w, 294, 0.04), SKY)


def m_concrete():
    h, w, x, y = tile_canvas()
    c, hgt = concrete(h, w, x, y, 301, boards=False)
    c = c / 0.56 * 0.82
    return shade(c * grime(h, w, 302, 0.3, 0.2)[..., None], hgt, SKY)


def m_rubber():
    h, w, x, y = tile_canvas()
    c = grey(0.9, h, w) * (1 + 0.05 * noise(h, w, 311, 0.003) + 0.03 * noise(h, w, 312, 0.2))[..., None]
    scuff = sstep(1.0, 2.5, noise(h, w, 313, 0.04, sx=3))
    return shade(c * (1 - 0.15 * scuff)[..., None], 0.0005 * noise(h, w, 314, 0.005), SKY, gloss=0.04)


def m_paper():
    h, w, x, y = tile_canvas()
    c = grey(0.95, h, w) * (1 + 0.015 * noise(h, w, 321, 0.1))[..., None]
    row = np.floor(y / 0.09)
    word = np.floor(x / 0.06)
    ink = ((y % 0.09) > 0.03) & ((y % 0.09) < 0.06) & (hash2(word, row, 322) > 0.25) & ((x % 0.06) > 0.01)
    ink &= (x > 0.08) & (x < 0.92) & (y > 0.08) & (y < 0.92) & (hash2(row, 0, 323) > 0.1)
    ink = blur(ink.astype(np.float32), 0.004)
    c = c * (1 - 0.45 * ink)[..., None]
    return shade(c, np.zeros((h, w), np.float32), SKY)


def m_steel():
    h, w, x, y = tile_canvas()
    rust = noise(h, w, 331, 0.08, beta=1.2)
    c = col(rgb("8c8a86"), h, w) * (1 + 0.04 * noise(h, w, 332, 0.002, sx=40))[..., None]
    c = mix(c, rgb("8a4b26"), sstep(-0.2, 1.2, rust) * 0.85)
    c = mix(c, rgb("5a2e17"), sstep(1.2, 2.2, rust) * 0.7)
    c = c + scratches(h, w, 333, 30, 0.05, 0.2)[..., None]
    pits = specks(h, w, 334, 0.004, 0.003) * sstep(0.0, 1.0, rust)
    return shade(c, 0.002 * rust - pits * 0.002, SKY, gloss=0.05)


def m_soil():
    h, w, x, y = tile_canvas()
    c = grey(0.78, h, w) * (1 + 0.1 * noise(h, w, 341, 0.08, beta=1.2) + 0.04 * noise(h, w, 342, 0.03))[..., None]
    peb = sstep(2.0, 2.3, noise(h, w, 343, 0.025))
    c = mix(c, grey(0.95, h, w), peb * 0.8)
    return shade(c, 0.006 * noise(h, w, 345, 0.04, beta=1) + peb * 0.008, SKY, relief=1.0, cast=0.7)


def m_books():
    """Spines in a library's colours: widths 2-5 cm, worn edges, titles in bands."""
    h, w, x, y = tile_canvas()
    rng = np.random.default_rng(351)
    edges = np.cumsum(rng.uniform(0.02, 0.055, 60))
    edges = edges[edges < 1.0]
    edges = np.append(edges[:-1], 1.0) if edges[-1] > 0.95 else np.append(edges, 1.0)
    idx = np.searchsorted(edges, x[0])
    lib = [rgb(c) for c in ("5c1a14", "1f3d26", "1d2a4a", "7a6040", "1b1a18", "b7aa8c", "6b3e1a", "3e1a36", "2f4f4f", "8a7a5a")]
    starts = np.concatenate([[0], edges[:-1]])
    c = np.zeros((h, w, 3), np.float32)
    hgt = np.zeros((h, w), np.float32)
    for b in range(len(edges)):
        sel = idx == b
        bc = lib[rng.integers(len(lib))] * (0.8 + 0.4 * rng.random())
        top = rng.uniform(0.0, 0.12)                 # shorter books leave a gap above
        band = rng.uniform(0.15, 0.3)
        u = (x[:, sel] - starts[b]) / (edges[b] - starts[b])
        cc = np.broadcast_to(bc, (h, sel.sum(), 3)).copy()
        yy = y[:, sel]
        title = (np.abs(yy - band) < 0.03) | (np.abs(yy - band - 0.5) < 0.015)
        cc = np.where(title[..., None], np.minimum(cc * 1.8 + 0.15, 1), cc)
        cc *= (0.75 + 0.25 * np.sin(np.clip(u, 0, 1) * np.pi))[..., None]
        gap = (yy % 0.5) < top
        cc = np.where(gap[..., None], cc * 0.12, cc)
        c[:, sel] = cc
        hgt[:, sel] = np.where(gap, -0.01, 0.004 * np.sin(np.clip(u, 0, 1) * np.pi))
    c = c * (1 + 0.06 * noise(h, w, 352, 0.004))[..., None]
    return shade(c, hgt, SKY, cast=0.5)


def m_goods():
    h, w, x, y = tile_canvas()
    row = np.floor(y / 0.25)
    item = np.floor(x / 0.125)
    v = (y % 0.25) / 0.25
    hue = hash2(item, row, 361)
    import colorsys
    pal = np.array([colorsys.hsv_to_rgb(t, 0.45, 0.55) for t in np.linspace(0, 1, 16, endpoint=False)], np.float32)
    c = pal[(hue * 16).astype(int) % 16] * (0.8 + 0.4 * hash2(item, row, 362))[..., None]
    label = (v > 0.45) & (v < 0.7)
    c = np.where(label[..., None], mix(c, np.array([0.93, 0.92, 0.88]), 0.75), c)
    gap = ((x % 0.125) > 0.11) | (v < 0.12)
    c = np.where(gap[..., None], col(rgb("1c1c1e"), h, w), c)
    c = c * (1 + 0.04 * noise(h, w, 363, 0.005))[..., None]
    return shade(c, np.where(gap, -0.01, 0.0).astype(np.float32), SKY, cast=0.5)


def m_cushion():
    h, w, x, y = tile_canvas()
    u, v, i, j, d = cells(x, y, 0.25, 0.25, stagger=0.5)
    r = np.hypot(np.minimum(u, 0.25 - u), np.minimum(v, 0.25 - v))
    puff = sstep(0.0, 0.1, r)
    c = grey(0.88, h, w) * (1 + 0.04 * noise(h, w, 371, 0.004) + 0.03 * noise(h, w, 372, 0.2))[..., None]
    c = c * (0.7 + 0.3 * puff)[..., None]
    return shade(c, 0.02 * puff, SKY, relief=1.0, cast=0.3)


def m_grille():
    h, w, x, y = tile_canvas()
    slot = ((y % 0.125) > 0.05) & ((x % 0.5) > 0.04) & ((x % 0.5) < 0.46)
    c = grey(0.8, h, w) * (1 + 0.04 * noise(h, w, 381, 0.1))[..., None]
    c = np.where(slot[..., None], c * 0.18, c)
    hgt = np.where(slot, -0.01, 0.0).astype(np.float32)
    return shade(c * grime(h, w, 382, 0.3, 0.15)[..., None], hgt, SKY, cast=0.8)


def m_screen():
    h, w, x, y = tile_canvas()
    c = col(rgb("08201c"), h, w) * (1 + 0.15 * noise(h, w, 391, 0.3))[..., None]
    line = ((y % 0.06) > 0.02) & ((y % 0.06) < 0.04) & (hash2(np.floor(x / 0.04), np.floor(y / 0.06), 392) > 0.4)
    line &= (x > 0.05) & (x < 0.95)
    c = np.where(line[..., None], col(rgb("5fe0a6"), h, w), c)
    c = c * (0.92 + 0.08 * ((y * M) % 3 > 1))[..., None]
    return c


def m_snow():
    h, w, x, y = tile_canvas()
    d = noise(h, w, 401, 0.2, beta=1.0)
    c = col(rgb("e6edf7"), h, w) * (1 + 0.015 * noise(h, w, 402, 0.04))[..., None]
    return shade(c, 0.01 * d, SKY, amb=0.7, ao=0.5)


def m_cardboard():
    h, w, x, y = tile_canvas()
    flute = np.sin(x * 2 * np.pi / 0.008) * 0.5
    c = grey(0.84, h, w) * (1 + 0.02 * flute + 0.05 * noise(h, w, 411, 0.15) + 0.03 * noise(h, w, 412, 0.004))[..., None]
    tape = (np.abs(y - 0.5) < 0.04)
    c = np.where(tape[..., None], c * 1.08 + 0.02, c)
    c = c * grime(h, w, 413, 0.2, 0.2)[..., None]
    return shade(c, 0.0005 * flute + tape * 0.001, SKY, gloss=0.0)


def m_tile():
    h, w, x, y = tile_canvas()
    u, v, i, j, d = cells(x, y, 0.25, 0.25)
    b = bevel(d, 0.004, 0.006)
    face = grey(0.95, h, w) * (1 + 0.025 * (hash2(i, j, 421) - 0.5) + 0.01 * noise(h, w, 422, 0.1))[..., None]
    c = mix(grey(0.58, h, w), face, b)
    c = c * grime(h, w, 423, 0.2, 0.12)[..., None]
    return shade(c, 0.003 * b, SKY, gloss=0.25)


def m_chrome():
    h, w, x, y = tile_canvas()
    refl = 0.5 + 0.5 * np.sin(y * 9 + 2.0 * noise(h, w, 431, 0.4))
    c = grey(1, h, w) * (0.55 + 0.45 * refl)[..., None]
    c = c - scratches(h, w, 432, 30, 0.05, 0.1)[..., None]
    return c


def m_solar():
    h, w, x, y = tile_canvas()
    u, v, i, j, d = cells(x, y, 1 / 6, 1 / 6)
    cell = mix(rgb("0f1d3d"), rgb("1f3a73"), np.clip(0.4 + 0.25 * noise(h, w, 441, 0.3) + 0.2 * (hash2(i, j, 442) - 0.5), 0, 1))
    cell = cell * (1 + 0.06 * noise(h, w, 443, 0.004))[..., None]
    bus = (np.abs(u - 1 / 12) < 0.0015)
    c = mix(cell, rgb("8a96a8"), bus * 0.5)
    frame = d < 0.003
    c = np.where(frame[..., None], col(rgb("c3c8cf"), h, w), c)
    return shade(c, 0.001 * (d > 0.004), SKY, gloss=0.4)


def m_mesh():
    h, w, x, y = tile_canvas()
    wx = np.abs(((x + y) % 0.0625) - 0.03125) < 0.005
    wy = np.abs(((x - y) % 0.0625) - 0.03125) < 0.005
    wire = (wx | wy).astype(np.float32)
    c = mix(grey(0.12, h, w), grey(0.82, h, w) * (1 + 0.05 * noise(h, w, 451, 0.1))[..., None], wire)
    return shade(c, 0.004 * wire, SKY, cast=0.6)


def m_gravel():
    h, w, x, y = tile_canvas()
    u, v, i, j, d = cells(x, y, 0.07, 0.06, stagger=0.5)
    jit = noise(h, w, 461, 0.02) * 0.01
    stone = bevel(d + jit, 0.004, 0.015)
    c = grey(1, h, w) * (0.55 + 0.4 * hash2(i, j, 462))[..., None] * (1 + 0.05 * noise(h, w, 463, 0.02))[..., None]
    c = mix(grey(0.3, h, w), c, stone)
    return shade(c, 0.012 * stone, SKY, relief=1.0, cast=0.8)


def m_planks():
    h, w, x, y = tile_canvas()
    u, v, i, j, d = cells(y, x, 0.25, 1.0)                      # boards along x, 25 cm wide
    j = np.floor(y / 0.25)
    joint = sstep(0.004, 0.0, np.minimum(y % 0.25, 0.25 - y % 0.25))
    grain = noise(h, w, 471, 0.004, sx=25) * 0.6 + np.sin((y + 0.03 * noise(h, w, 472, 0.1, sx=5)) * 2 * np.pi * 30) * 0.4
    tone = 0.8 + 0.12 * hash2(j, 0, 473)
    c = grey(1, h, w) * (tone + 0.08 * grain)[..., None]
    knot = (np.hypot(((x + hash2(j, 1, 474)) % 1.0) - 0.5, (y % 0.25) - 0.12) < 0.015)
    c = mix(c, c * 0.55, knot)
    c = mix(c, grey(0.35, h, w), joint)
    nail = (np.hypot((x % 0.5) - 0.06, (y % 0.25) - 0.125) < 0.005)
    c = mix(c, grey(0.3, h, w), nail)
    c = c * grime(h, w, 475, 0.3, 0.2)[..., None]
    return shade(c, 0.004 * (1 - joint) + 0.0005 * grain, SKY)


def m_grass():
    h, w, x, y = tile_canvas()
    c, hgt = turf(h, w, 481)
    return shade(c, hgt, SKY, relief=1.0, cast=0.6)


MATERIALS = [m_plain, m_wood, m_metal, m_plate, m_fabric, m_plastic, m_ceramic, m_leaves, m_bark,
             m_burlap, m_concrete, m_rubber, m_paper, m_steel, m_soil, m_books, m_goods, m_cushion,
             m_grille, m_screen, m_snow, m_cardboard, m_tile, m_chrome, m_solar, m_mesh, m_gravel,
             m_planks, m_grass]


# --- open ground: 8 m seamless tiles ---------------------------------------------------------------
def turf(h, w, seed):
    """Grass seen from above: clumps, blades catching light, dry patches, bare soil."""
    big = noise(h, w, seed, 1.2, beta=0.8)
    clump = noise(h, w, seed + 1, 0.04, beta=0.6)
    blades = noise(h, w, seed + 2, 0.003, sx=0.5) * 0.6 + noise(h, w, seed + 3, 0.003, sy=0.5) * 0.4
    lush, dry = rgb("3a5a22"), rgb("75773f")
    c = mix(col(lush, h, w), col(dry, h, w), sstep(0.3, 1.8, big) * 0.7)
    c = mix(c, col(rgb("27401a"), h, w), sstep(0.2, -1.5, clump) * 0.6)
    c = c * (1 + 0.18 * blades)[..., None]
    soil = sstep(1.9, 2.3, noise(h, w, seed + 4, 0.25)) * sstep(0.0, 1.0, big)
    c = mix(c, col(rgb("5a4630"), h, w) * (1 + 0.1 * noise(h, w, seed + 5, 0.01))[..., None], soil)
    flowers = (np.random.default_rng(seed + 6).random((h, w)) < 0.00002).astype(np.float32)
    fl = np.clip(blur(flowers, 0.006) * 400, 0, 1)
    c = mix(c, rgb("e6dc8c"), fl * 0.8)
    hgt = 0.01 * clump + 0.004 * blades - soil * 0.01
    return c, hgt


def g_grass():
    h = w = 256 * SS
    c, hgt = turf(h, w, 501)
    return shade(c, hgt, SKY, relief=1.0, cast=0.6)


def g_earth():
    h = w = 256 * SS
    big = noise(h, w, 511, 1.0, beta=0.9)
    c = mix(col(rgb("5c4630"), h, w), col(rgb("7a6448"), h, w), sstep(-1.5, 1.5, big + 0.5 * noise(h, w, 512, 0.15)))
    c = c * (1 + 0.1 * noise(h, w, 513, 0.006))[..., None]
    clods = noise(h, w, 514, 0.05, beta=1.0)
    peb = sstep(2.0, 2.4, noise(h, w, 515, 0.012))
    c = mix(c, col(rgb("8f887d"), h, w) * (1 + 0.15 * noise(h, w, 516, 0.006))[..., None], peb)
    crack = (np.abs(noise(h, w, 517, 0.5, beta=1.3)) < 0.02) * sstep(0.0, 1.0, big)
    c = mix(c, rgb("2e2216"), crack * 0.7)
    tufts = sstep(2.2, 2.6, noise(h, w, 518, 0.03))
    c = mix(c, rgb("566a2e"), tufts * 0.7)
    hgt = 0.012 * clods + peb * 0.01 - crack * 0.01 + tufts * 0.006
    return shade(c, hgt, SKY, relief=1.0, cast=0.6)


def g_snow():
    h = w = 256 * SS
    drift = noise(h, w, 521, 0.8, beta=1.0)
    c = col(rgb("eef3fb"), h, w) * (1 + 0.012 * noise(h, w, 522, 0.05))[..., None]
    c = mix(c, col(rgb("c7d3e6"), h, w), sstep(0.5, -1.5, drift) * 0.35)
    poke = sstep(2.3, 2.6, noise(h, w, 524, 0.02))
    c = mix(c, rgb("5a5236"), poke * 0.6)
    return shade(c, 0.03 * drift, SKY, amb=0.7, ao=0.4)


GROUNDS = [g_grass, g_earth, g_snow]


# --- doors, ceilings, roofs, moon --------------------------------------------------------------------
def door(style):
    h, w = 68 * SS, (32 if style == "wood" else 16) * SS
    x, y = grid(h, w)
    W, H = w / M, h / M
    f = H - y
    if style == "wood":
        c = col(rgb("6a4a30"), h, w) * (1 + 0.08 * noise(h, w, 601, 0.004, sy=14))[..., None]
        panel = ((x > 0.16) & (x < 0.84)) & (((f > 1.15) & (f < 1.95)) | ((f > 0.18) & (f < 0.98)))
        pd = np.minimum(np.minimum(x - 0.16, 0.84 - x), np.minimum(np.abs(f - 1.55) - 0.0, 9))
        pd = np.where(f > 1.06, np.minimum(np.minimum(x - 0.16, 0.84 - x), np.minimum(f - 1.15, 1.95 - f)),
                      np.minimum(np.minimum(x - 0.16, 0.84 - x), np.minimum(f - 0.18, 0.98 - f)))
        hgt = np.where(panel, -0.008 + 0.006 * bevel(pd, 0.0, 0.03), 0.0)
        knob = np.hypot(x - 0.86, f - 1.0) < 0.03
        c = np.where(knob[..., None], col(rgb("b8963c"), h, w), c)
        hgt = hgt + knob * 0.02
        c = c * floor_dirt(h, w, f, 602, 0.3, 0.3)[..., None] * grime(h, w, 603, 0.2, 0.15)[..., None]
        c = c + scratches(h, w, 604, 30, 0.06, 0.08)[..., None]
        return shade(c, hgt, TOP, cast=0.5)
    c = col(rgb("6c747b"), h, w) * (1 + 0.04 * noise(h, w, 611, 0.2) + 0.02 * noise(h, w, 612, 0.002, sy=30))[..., None]
    win = (x > 0.11) & (x < 0.39) & (f > 1.35) & (f < 1.8)
    wd = np.minimum(np.minimum(x - 0.11, 0.39 - x), np.minimum(f - 1.35, 1.8 - f))
    glass = mix(rgb("1d2a30"), rgb("4a6470"), np.clip((x - 0.11) * 2 + (f - 1.35) * 0.8, 0, 1))
    wire = ((np.abs((x % 0.04) - 0.02) < 0.002) | (np.abs((f % 0.04) - 0.02) < 0.002))
    glass = np.where(wire[..., None], glass * 0.6, glass)
    c = np.where(win[..., None], glass, c)
    hgt = np.where(win, -0.01 + 0.006 * bevel(wd, 0.0, 0.01), 0.0)
    kick = f < 0.3
    hz = (((x + f) / 0.08) % 2) < 1
    kc = np.where(hz[..., None], col(rgb("b88a1a"), h, w), col(rgb("1e1d1b"), h, w))
    kc = mix(kc, rgb("4a4640"), sstep(0.8, 2.0, noise(h, w, 613, 0.03)) * 0.8)
    c = np.where(kick[..., None], kc, c)
    for rx in (0.06, 0.44):
        for ry in np.arange(0.4, 2.1, 0.4):
            hgt = hgt + (np.hypot(x - rx, f - ry) < 0.008) * 0.004
    c = c + scratches(h, w, 614, 25, 0.05, 0.15)[..., None]
    c = c * floor_dirt(h, w, f, 615, 0.35, 0.25)[..., None]
    return shade(c, hgt, TOP, gloss=0.08)


def ceiling(look):
    h, w, x, y = tile_canvas()
    if look == "metal":
        u, v, i, j, d = cells(x, y, 0.5, 0.5)
        b = bevel(d, 0.004, 0.008)
        perf = ((np.hypot((x % 0.03) - 0.015, (y % 0.03) - 0.015) < 0.004) & (d > 0.04)).astype(np.float32)
        c = grey(0.5, h, w) * (1 + 0.04 * noise(h, w, 701, 0.3) + 0.03 * (hash2(i, j, 702) - 0.5))[..., None]
        c = mix(c * 0.45, c, b) * (1 - 0.35 * blur(perf, 0.003) * 8)[..., None]
        c = c * grime(h, w, 703, 0.3, 0.2)[..., None]
        return shade(c, 0.004 * b, SKY)
    c = grey(0.68, h, w) * (1 + 0.03 * noise(h, w, 711, 0.3, beta=1) + 0.02 * noise(h, w, 712, 0.005))[..., None]
    stain = sstep(1.4, 2.4, noise(h, w, 713, 0.25))
    c = mix(c, c * np.array([0.85, 0.78, 0.62]), stain * 0.5)
    crack = ((np.abs(noise(h, w, 714, 0.3, beta=1.5)) < 0.02) & (noise(h, w, 715, 0.4) > 0.5)).astype(np.float32)
    c = mix(c, c * 0.6, crack)
    return shade(c, -crack * 0.002, SKY)


def roof(look):
    h, w, x, y = tile_canvas()
    if look == "metal":
        corr = np.sin(x * 2 * np.pi / 0.0625)
        c = grey(0.42, h, w) * (1 + 0.08 * corr + 0.05 * noise(h, w, 801, 0.2))[..., None]
        c = mix(c, rgb("6b3d22"), sstep(1.0, 2.2, noise(h, w, 802, 0.06, sy=4)) * 0.6)
        return shade(c, 0.006 * corr, SKY, gloss=0.05)
    row = np.floor(y / 0.125)
    xo = x + (row % 2) * 0.0625
    i = np.floor(xo / 0.125)
    v = (y % 0.125) / 0.125
    u = (xo % 0.125) / 0.125
    tone = hash2(i, row, 811)
    c = mix(col(rgb("7a3a26"), h, w), col(rgb("9a5236"), h, w), tone)
    c = c * (0.7 + 0.3 * sstep(0.0, 0.25, v))[..., None] * (0.85 + 0.15 * np.sin(u * np.pi))[..., None]
    moss = sstep(1.3, 2.3, noise(h, w, 812, 0.15))
    c = mix(c, rgb("4e5a2c"), moss * 0.6)
    hgt = 0.01 * v + 0.004 * np.sin(u * np.pi)
    if look == "snow":
        cover = sstep(-0.5, 0.5, noise(h, w, 813, 0.15) + 1.4)
        snow = col(rgb("e8eef8"), h, w) * (1 + 0.015 * noise(h, w, 814, 0.04))[..., None]
        c = mix(c, snow, cover)
        hgt = hgt + 0.01 * cover
    return shade(c, hgt, SKY, cast=0.6)


def moon():
    h = w = 32 * SS
    x, y = grid(h, w)
    r = np.hypot(x - 0.5 * w / M, y - 0.5 * h / M) / (15 / PX)
    maria = sstep(0.2, 1.4, noise(h, w, 901, 0.06, beta=1.0))
    c = grey(0.92, h, w) * (1 - 0.3 * maria - 0.04 * noise(h, w, 902, 0.03))[..., None]
    c = c * (0.85 + 0.15 * np.sqrt(np.clip(1 - r * r, 0, 1)))[..., None]
    a = (r < 1).astype(np.float32)
    return np.concatenate([c, a[..., None]], -1)


def fire():
    """A flame standing on the floor, seen from the side, for the first-person billboard
    (issues-12 #18): a broad hot base narrowing into tongues with dark red tips; alpha cuts
    the silhouette (1.15 m wide, 1.35 m tall in game)."""
    h = w = 32 * SS
    x, y = grid(h, w)
    rise = 1 - y                                         # 0 at the base, 1 at the top
    tongues = noise(h, w, 951, 0.09, sy=4.0)
    flick = noise(h, w, 952, 0.04, sy=2.5)
    # Narrower the higher it reaches, so it reads as one fire, not a wall of flame.
    side = np.abs(x - 0.5) * 2.0
    density = (1 - rise) * 2.2 + 0.7 * tongues + 0.2 * flick - 1.0 - side * side * (1.5 + 2.4 * rise)
    heat = np.clip(density * 1.05, 0, 1)
    stops = [(0.0, "5a0d04"), (0.3, "c2360c"), (0.55, "f07a18"), (0.8, "ffc246"), (1.0, "fff0b0")]
    c = col(rgb(stops[0][1]), h, w)
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        c = np.where(((heat >= t0) & (heat <= t1))[..., None], mix(col(rgb(c0), h, w), col(rgb(c1), h, w), (heat - t0) / (t1 - t0)), c)
    ember = (np.random.default_rng(953).random((h, w)) < 0.0004) & (rise > 0.3)
    ember = np.clip(blur(ember.astype(np.float32), 0.004) * 60, 0, 1)
    a = np.clip((density > 0) + ember, 0, 1).astype(np.float32)
    c = mix(c, rgb("ff9a30"), ember)
    return np.concatenate([c, a[..., None]], -1)


def smoke():
    """Soft billows for smoke and gas (tinted by their colour): grey, partly see-through."""
    h = w = 32 * SS
    b = noise(h, w, 961, 0.15, beta=0.5) * 0.7 + noise(h, w, 962, 0.05) * 0.3
    v = 0.78 + 0.12 * b
    a = np.clip(0.85 + 0.3 * b, 0.4, 1)
    return np.concatenate([col((1, 1, 1), h, w) * v[..., None], a[..., None]], -1)


# --- first-person floors: six 1 m variants of each board floor look ------------------------------------
# Each variant shares the common rim and broad shading of its floor (so any two join with no
# frame) and differs inside it in small things: wear, stains, cracks and specks move from cell
# to cell instead of repeating every metre.
def f_deck(h, w, x, y, s, tint="3a3f46"):
    u, v, i, j, d = cells(x, y, 0.5, 0.5)
    b = bevel(d, 0.004, 0.01)
    c = col(rgb(tint), h, w) * (1 + 0.05 * noise(h, w, s, 0.25, beta=1) + 0.04 * (hash2(i, j, 11) - 0.5))[..., None]
    tread = 0.5 + 0.5 * np.sin((x + y) * 2 * np.pi / 0.06) * np.sin((x - y) * 2 * np.pi / 0.06)
    c = c * (0.92 + 0.12 * tread)[..., None]
    wear = sstep(0.0, 2.0, noise(h, w, s + 1, 0.3, sx=1.5))
    c = mix(c, c * 1.5 + 0.06, wear * 0.35 * tread)
    c = mix(c * 0.4, c, b)
    hgt = 0.005 * b + 0.001 * tread
    for bx in (0.04, 0.46):
        for by in (0.04, 0.46):
            bolt = np.hypot(u - bx, v - by) < 0.009
            hgt = hgt + bolt * 0.003
            c = mix(c, c * 1.4, bolt * 0.6)
    c = mix(c, rgb("15130f"), sstep(1.6, 2.4, noise(h, w, s + 2, 0.12)) * 0.5)        # oil
    c = c + scratches(h, w, s + 3, 25, 0.06, 0.1)[..., None]
    return c, hgt


def f_concrete(h, w, x, y, s, base="8a8780"):
    c = col(rgb(base), h, w) * (1 + 0.05 * noise(h, w, s, 0.4, beta=1) + 0.06 * noise(h, w, s + 1, 0.004))[..., None]
    trowel = np.sin((np.hypot(x - 0.5, y - 0.5) + 0.05 * noise(h, w, s + 2, 0.2)) * 2 * np.pi * 7)
    c = c * (1 + 0.02 * trowel)[..., None]
    agg = specks(h, w, s + 3, 0.004, 0.003)
    c = c * (1 - 0.25 * agg + 0.0)[..., None]
    crack = ((np.abs(noise(h, w, s + 4, 0.35, beta=1.4)) < 0.018) & (noise(h, w, s + 5, 0.3) > 0.7)).astype(np.float32)
    c = mix(c, rgb("2a2824"), crack * 0.8)
    c = mix(c, c * np.array([0.8, 0.78, 0.72]), sstep(1.2, 2.2, noise(h, w, s + 6, 0.15)) * 0.5)
    joint = sstep(0.004, 0.0, np.minimum(np.minimum(x, 1 - x), np.minimum(y, 1 - y)))
    c = mix(c, c * 0.5, joint)
    return c, -crack * 0.004 - agg * 0.002 - joint * 0.004


def f_regolith(h, w, x, y, s):
    big = noise(h, w, s, 0.3, beta=1.2)
    c = mix(col(rgb("5d5650"), h, w), col(rgb("7d746a"), h, w), sstep(-1.5, 1.5, big))
    c = c * (1 + 0.1 * noise(h, w, s + 1, 0.004))[..., None]
    peb = sstep(1.9, 2.3, noise(h, w, s + 2, 0.015))
    c = mix(c, col(rgb("8e877d"), h, w), peb)
    cr = np.hypot((x + 0.1 * noise(h, w, s + 3, 0.3)) - 0.5, y - 0.5)
    pit = sstep(0.12, 0.08, cr) * (hash2(s, 0, 3) > 0.5)
    return c, 0.015 * big + 0.008 * peb - 0.01 * pit


def f_carpet(h, w, x, y, s, tint):
    c = col(rgb(tint), h, w)
    u, v, i, j, d = cells(x + y, x - y, 0.25 * 1.4142, 0.25 * 1.4142)
    line = sstep(0.012, 0.0, d)
    c = mix(c, c * 0.75, line * 0.6)
    dot = np.hypot((x % 0.25) - 0.125, (y % 0.25) - 0.125) < 0.012
    c = mix(c, rgb("c9b37a"), dot * 0.6)
    c = c * (1 + 0.1 * noise(h, w, s, 0.003) + 0.05 * noise(h, w, s + 1, 0.3, beta=1))[..., None]
    worn = sstep(0.3, 2.0, noise(h, w, s + 2, 0.4, sx=0.6))
    c = mix(c, c * 1.25 + 0.03, worn * 0.4)
    c = mix(c, c * 0.6, sstep(1.5, 2.3, noise(h, w, s + 3, 0.1)) * 0.6)                 # stains
    return c, 0.002 * noise(h, w, s + 4, 0.004)


def f_checker(h, w, x, y, s):
    u, v, i, j, d = cells(x, y, 0.25, 0.25)
    b = bevel(d, 0.003, 0.006)
    white = ((i + j) % 2) == 0
    c = np.where(white[..., None], col(rgb("e2ddcf"), h, w), col(rgb("26262a"), h, w))
    c = c * (1 + 0.03 * noise(h, w, s, 0.15) + 0.02 * (hash2(i, j, 21) - 0.5))[..., None]
    c = mix(c, col(rgb("6e6a60"), h, w), sstep(0.0, 0.3, 1 - b))
    c = c * grime(h, w, s + 1, 0.3, 0.25)[..., None] + scratches(h, w, s + 2, 20, 0.05, 0.1)[..., None]
    return c, 0.003 * b


def f_destroyed(h, w, x, y, s):
    c, hgt = f_concrete(h, w, x, y, s, "7b7872")
    cr = noise(h, w, s + 10, 0.12, beta=1.0)
    crack = np.abs(cr) < 0.06
    c = mix(c, rgb("1c1b19"), crack * 0.85)
    chunk = sstep(0.0, 1.5, noise(h, w, s + 11, 0.08))
    hgt = hgt + 0.02 * chunk - crack * 0.02
    dust = sstep(0.5, 2.0, noise(h, w, s + 12, 0.2))
    c = mix(c, rgb("9a958a"), dust * 0.4)
    deb = sstep(2.0, 2.4, noise(h, w, s + 13, 0.01))
    c = mix(c, rgb("5a5751"), deb)
    return c, hgt + deb * 0.01


def f_epicenter(h, w, x, y, s):
    c = mix(col(rgb("141210"), h, w), col(rgb("3a3631"), h, w), sstep(-1.0, 1.5, noise(h, w, s, 0.2, beta=1.2)))
    c = c * (1 + 0.15 * noise(h, w, s + 1, 0.004))[..., None]
    ash = sstep(1.0, 2.2, noise(h, w, s + 2, 0.06))
    c = mix(c, rgb("6e6a64"), ash * 0.5)
    ember = specks(h, w, s + 3, 0.0008, 0.002)
    c = mix(c, rgb("ff6a1e"), np.clip(ember * 2, 0, 1) * 0.8)
    return c, 0.01 * noise(h, w, s + 4, 0.05, beta=1)


def f_field(h, w, x, y, s):
    c = mix(col(rgb("5f4a33"), h, w), col(rgb("7a6448"), h, w), sstep(-1.5, 1.5, noise(h, w, s, 0.3, beta=1)))
    c = c * (1 + 0.1 * noise(h, w, s + 1, 0.005))[..., None]
    g = sstep(1.0, 2.0, noise(h, w, s + 2, 0.05))
    c = mix(c, rgb("566a2e") * (1 + 0.2 * noise(h, w, s + 3, 0.003))[..., None], g * 0.8)
    return c, 0.008 * noise(h, w, s + 4, 0.05, beta=1) + g * 0.004


def f_grass(h, w, x, y, s):
    return turf(h, w, s)


def f_grate(h, w, x, y, s):
    bx = sstep(0.009, 0.005, np.minimum(x % 0.125, 0.125 - x % 0.125))
    by = sstep(0.007, 0.004, np.minimum(y % 0.0625, 0.0625 - y % 0.0625))
    bar = np.maximum(bx, by)
    metal = col(rgb("7b8186"), h, w) * (1 + 0.1 * noise(h, w, s, 0.1))[..., None]
    metal = mix(metal, rgb("6b3d22"), sstep(1.0, 2.2, noise(h, w, s + 1, 0.08)) * 0.6)
    c = mix(col(rgb("0b0c0d"), h, w), metal, bar)
    return c, 0.02 * bar


def f_grill(h, w, x, y, s):
    u, v, i, j, d = cells(x + 0.5 * y, y, 0.125, 0.0625, stagger=0.5)
    strand = sstep(0.016, 0.011, d)
    metal = col(rgb("8a9096"), h, w) * (1 + 0.1 * noise(h, w, s, 0.1))[..., None]
    metal = mix(metal, rgb("5a3a24"), sstep(1.2, 2.2, noise(h, w, s + 1, 0.06)) * 0.5)
    return metal, 0.01 * strand, strand


def f_lino(h, w, x, y, s):
    c = col(rgb("9fb3a2"), h, w) * (1 + 0.06 * noise(h, w, s, 0.02) + 0.04 * noise(h, w, s + 1, 0.3, beta=1))[..., None]
    fl = specks(h, w, s + 2, 0.006, 0.0025)
    c = mix(c, rgb("e8ece4"), fl * 0.5)
    heel = sstep(1.8, 2.4, noise(h, w, s + 3, 0.02, sx=3))
    c = mix(c, rgb("2a2a2a"), heel * 0.6)
    c = c * grime(h, w, s + 4, 0.4, 0.2)[..., None]
    return c, np.zeros((h, w), np.float32)


def f_parquet(h, w, x, y, s):
    sq = np.floor(x / 0.25) + np.floor(y / 0.25)
    along = (sq % 2) == 0
    a = np.where(along, x, y)
    b2 = np.where(along, y, x)
    strip = np.floor(b2 / 0.0625)
    sd = np.minimum(np.minimum(b2 % 0.0625, 0.0625 - b2 % 0.0625), np.minimum(a % 0.25, 0.25 - a % 0.25))
    tone = hash2(strip, np.floor(a / 0.25) * 7 + sq, 31)
    wood = mix(rgb("6a4126"), rgb("9c6a40"), tone)
    grain = noise(h, w, s, 0.003, sx=6) * np.where(along, 1, 0) + noise(h, w, s + 1, 0.003, sy=6) * np.where(along, 0, 1)
    c = wood * (1 + 0.1 * grain)[..., None]
    c = mix(c * 0.45, c, sstep(0.0, 0.004, sd))
    worn = sstep(0.3, 2.0, noise(h, w, s + 2, 0.4))
    c = mix(c, c * 1.15 + 0.04, worn * 0.4)
    return c, 0.003 * sstep(0.0, 0.004, sd)


def f_plate(h, w, x, y, s):
    u, v, i, j, d = cells(x, y, 0.06, 0.06, stagger=0.5)
    a = np.where((i % 2) == 0, u / 0.06 - 0.5, v / 0.06 - 0.5)
    b2 = np.where((i % 2) == 0, v / 0.06 - 0.5, u / 0.06 - 0.5)
    lens = sstep(0.12, 0.05, (a / 0.4) ** 2 * 0.25 + (b2 / 0.12) ** 2 * 0.25)
    c = col(rgb("8e9296"), h, w) * (1 + 0.06 * noise(h, w, s, 0.2, beta=1))[..., None]
    c = mix(c, c * 1.3 + 0.05, lens * sstep(0.0, 1.5, noise(h, w, s + 1, 0.3)) * 0.5)
    c = mix(c, rgb("6e3f22"), sstep(1.4, 2.3, noise(h, w, s + 2, 0.08)) * 0.6)
    c = c * grime(h, w, s + 3, 0.3, 0.25)[..., None]
    return c, 0.004 * lens


def f_snow(h, w, x, y, s):
    d = noise(h, w, s, 0.5)
    c = col(rgb("e9eff8"), h, w) * (1 + 0.012 * noise(h, w, s + 1, 0.04))[..., None]
    c = mix(c, col(rgb("c3cfe2"), h, w), sstep(0.5, -1.5, d) * 0.18)
    return c, 0.005 * d


def f_snow_field(h, w, x, y, s):
    c, hgt = f_snow(h, w, x, y, s)
    patch = sstep(1.5, 2.0, noise(h, w, s + 5, 0.2))
    dirt, dh = f_field(h, w, x, y, s + 6)
    return mix(c, dirt, patch), hgt * (1 - patch) + dh * patch


def f_solar(h, w, x, y, s):
    u, v, i, j, d = cells(x, y, 1 / 6, 1 / 6)
    cell = mix(rgb("0f1d3d"), rgb("23427e"), np.clip(0.4 + 0.25 * noise(h, w, s, 0.3) + 0.2 * (hash2(i, j, 41) - 0.5), 0, 1))
    bus = (np.abs(u - 1 / 18) < 0.002) | (np.abs(u - 2 / 18) < 0.002)
    c = np.where(bus[..., None], col(rgb("8a96a8"), h, w), cell)
    frame = np.minimum(np.minimum(x, 1 - x), np.minimum(y, 1 - y)) < 0.02
    c = np.where((d < 0.003)[..., None], col(rgb("0a0f1a"), h, w), c)
    c = np.where(frame[..., None], col(rgb("b9bec6"), h, w), c)
    c = c * (1 - 0.15 * sstep(1.0, 2.2, noise(h, w, s + 1, 0.15)))[..., None]      # dust
    return c, 0.003 * frame


def f_tile(h, w, x, y, s):
    u, v, i, j, d = cells(x, y, 0.25, 0.25)
    b = bevel(d, 0.003, 0.006)
    face = col(rgb("e6e6e0"), h, w) * (1 + 0.02 * (hash2(i, j, 51) - 0.5) + 0.015 * noise(h, w, s, 0.1))[..., None]
    c = mix(col(rgb("7a766c"), h, w), face, b)
    c = c * grime(h, w, s + 1, 0.3, 0.2)[..., None] + scratches(h, w, s + 2, 10, 0.04, 0.05)[..., None]
    cracked = (np.abs(noise(h, w, s + 3, 0.1, beta=1.4)) < 0.02) * (hash2(i, j, s) > 0.85)
    c = mix(c, rgb("5a5850"), cracked * 0.8)
    return c, 0.003 * b


def f_asphalt(h, w, x, y, s):
    c = col(rgb("3e3e3d"), h, w) * (1 + 0.05 * noise(h, w, s, 0.4, beta=1))[..., None]
    agg = noise(h, w, s + 1, 0.004)
    c = c * (1 + 0.2 * agg)[..., None]
    stones = specks(h, w, s + 2, 0.008, 0.0025)
    c = mix(c, rgb("8f8b84"), stones * 0.6)
    crack = (np.abs(noise(h, w, s + 3, 0.4, beta=1.5)) < 0.015) * (noise(h, w, s + 4, 0.3) > 0.4)
    c = mix(c, rgb("141414"), crack * 0.9)
    oil = sstep(1.5, 2.3, noise(h, w, s + 5, 0.15))
    c = mix(c, rgb("1d1c1b"), oil * 0.5)
    patch = sstep(1.8, 2.0, noise(h, w, s + 6, 0.3))
    c = mix(c, c * 0.75, patch)
    return c, 0.003 * agg - crack * 0.006


def f_town_snow(h, w, x, y, s):
    a, ah = f_asphalt(h, w, x, y, s)
    sn, sh = f_snow(h, w, x, y, s + 7)
    cover = sstep(-1.9, -1.1, noise(h, w, s + 8, 0.35))
    slush = mix(blur(a.mean(-1), 0.03)[..., None] * np.array([0.95, 0.97, 1.0]), sn, 0.6)
    return mix(slush, sn, cover), ah * (1 - cover) + sh * cover


def f_planks(h, w, x, y, s):
    row = np.floor(y / 0.125)
    xo = x + hash2(row, 0, 61) * 1.0
    i = np.floor(xo / 1.0)
    joint = sstep(0.003, 0.0, np.minimum(y % 0.125, 0.125 - y % 0.125)) + sstep(0.003, 0.0, np.minimum(xo % 1.0, 1.0 - xo % 1.0)) * (hash2(row, 1, 62) > 0.5)
    joint = np.clip(joint, 0, 1)
    tone = hash2(row, i, 63)
    wood = mix(rgb("6e4a2e"), rgb("9a7046"), tone)
    grain = noise(h, w, s, 0.003, sx=12) * 0.6 + np.sin((y + 0.01 * noise(h, w, s + 1, 0.1, sx=4)) * 2 * np.pi * 60) * 0.4
    c = wood * (1 + 0.08 * grain)[..., None]
    worn = sstep(0.0, 2.0, noise(h, w, s + 2, 0.4))
    c = mix(c, c * 1.2 + 0.03, worn * 0.35)
    c = mix(c, rgb("1e140c"), joint * 0.85)
    c = c + scratches(h, w, s + 3, 20, 0.06, 0.06)[..., None]
    return c, 0.003 * (1 - joint)


FLOORS = {"floor": lambda *a: f_deck(*a, tint="44484d"), "floor_station": f_deck,
          "floor_asteroid": f_regolith, "floor_bunker": f_concrete,
          "floor_carpet_blue": lambda *a: f_carpet(*a, tint="233c6e"), "floor_carpet_red": lambda *a: f_carpet(*a, tint="6e1f22"),
          "floor_checker": f_checker, "floor_destroyed": f_destroyed, "floor_epicenter": f_epicenter,
          "floor_field": f_field, "floor_grass": f_grass, "floor_grate": f_grate, "floor_grill": f_grill,
          "floor_lino": f_lino, "floor_parquet": f_parquet, "floor_plate": f_plate, "floor_snow": f_snow,
          "floor_snow_field": f_snow_field, "floor_solar": f_solar, "floor_tile": f_tile,
          "floor_town": f_asphalt, "floor_town_snow": f_town_snow, "floor_wood": f_planks}


def floor_strip(name, seed):
    """Six variants side by side (192 x 32), as the board's floor strips are laid out."""
    h = w = M
    x, y = grid(h, w)
    inner = sstep(0.05, 0.18, np.minimum(np.minimum(x, 1 - x), np.minimum(y, 1 - y)))
    make = FLOORS[name]
    common = make(h, w, x, y, seed)
    parts = []
    for v in range(6):
        own = make(h, w, x, y, seed + 1000 * (v + 1))
        dc = own[0] - common[0]
        dc = dc - np.stack([blur(dc[..., k], 0.12) for k in range(3)], -1)
        dh = own[1] - common[1]
        c = common[0] + dc * inner[..., None]
        hgt = common[1] + (dh - blur(dh, 0.12)) * inner
        lit = shade(c, hgt, SKY, relief=0.9, cast=0.6)
        if len(common) > 2:
            a = common[2] * (1 - inner) + own[2] * inner
            lit = np.concatenate([lit, a[..., None]], -1)
        parts.append(down(lit))
    return np.concatenate(parts, 1)


# --- write everything ----------------------------------------------------------------------------------
# Mean brightness of the procedural pictures these replace: the light map and the shader
# were tuned against them, so the new art keeps their level.
BRIGHTNESS = {"wall_armor": 0.307, "wall_block": 0.54, "wall_brick": 0.323, "wall_bunker": 0.522,
              "wall_corpse": 0.172, "wall_dot": 0.477, "wall_dot_open": 0.45, "wall_rock": 0.316,
              "wall_sandbag": 0.501, "wall_soil": 0.328, "wall_station": 0.547, "wall_stucco": 0.719,
              "wall_wood": 0.322, "door_metal": 0.433, "door_wood": 0.322, "ceiling_metal": 0.368,
              "ceiling_plaster": 0.578, "roof_metal": 0.315, "roof_tiles": 0.269, "roof_snow": 0.86}


def main(only=None):
    def want(n):
        return only is None or any(n.startswith(o) for o in only)

    for i, make in enumerate(MATERIALS):
        n = "material_%02d.png" % i
        if want(n):
            a = down(make())
            target = old_mean(n)
            save(match(a, target) if target else a, n)
    for i, make in enumerate(GROUNDS):
        n = "ground_%02d.png" % i
        if want(n):
            a = down(make())
            target = old_mean(n)
            save(match(a, target) if target else a, n)
    for kind, make in WALLS.items():
        n = "wall_%s.png" % kind
        layer = "material_%02d.png" % (len(MATERIALS) + WALL_MATS.index(kind)) if kind in WALL_MATS else ""
        if want(n) or (layer and want(layer)):
            a = down(make())
            a = match(a, BRIGHTNESS["wall_" + kind]) if "wall_" + kind in BRIGHTNESS else a
            save(a, n)
            if layer:
                save(a[WALL_H - 43:WALL_H - 11, :PX], layer)
    for style in ("metal", "wood"):
        if want("door_" + style):
            save(match(down(door(style)), BRIGHTNESS["door_" + style]), "door_%s.png" % style)
    for look in ("metal", "plaster"):
        if want("ceiling_" + look):
            save(match(down(ceiling(look)), BRIGHTNESS["ceiling_" + look]), "ceiling_%s.png" % look)
    for look in ("metal", "tiles", "snow"):
        if want("roof_" + look):
            save(match(down(roof(look)), BRIGHTNESS["roof_" + look]), "roof_%s.png" % look)
    if want("moon"):
        save(down(moon()), "moon.png")
    if want("fire"):
        a = down(fire())
        a[..., 3] = (a[..., 3] > 0.5).astype(np.float32)      # crisp pixel flames
        save(a, "fire.png")
    if want("smoke"):
        save(down(smoke()), "smoke.png")
    for k, name in enumerate(FLOORS):
        n = "floors/fp_%s.png" % name
        if want(n):
            a = floor_strip(name, 3000 + k * 17)
            src = ROOT / "textures/floors" / name / (name + ".png")
            ref = np.asarray(Image.open(src).convert("RGBA")).astype(np.float32) / 255
            w8 = ref[..., 3]
            target = float((lum(ref[..., :3]) * w8).sum() / max(w8.sum(), 1e-6))
            if a.shape[-1] == 3:
                a = np.concatenate([a, np.ones(a.shape[:2] + (1,), np.float32)], -1)
            save(match(a, target), n)
    print("first-person textures written to", OUT)


if __name__ == "__main__":
    import sys
    main(sys.argv[1:] or None)
