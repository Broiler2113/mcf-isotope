"""Realistic top-down texture renderer for MCF Isotope (0.11 art pass).

Every texture is modelled, not painted: objects are built from height-mapped shapes with
real materials (wood grain, fabric, brushed/painted metal, concrete, ceramic, glass), lit
from the top-left with ambient occlusion, self-shadowing and a soft drop shadow, rendered
at SS x the final size and downscaled with a high-quality filter to 32 px per tile — the
"photo shrunk to 32x32" look of the reference sprites (a gas stove top and a sink).

Coordinates are in CELLS (1.0 = one game tile). Heights are in metres-ish units: the
shading only cares about slopes, so 1.0 = a tall cabinet, 0.02 = a seam.
Only numpy + PIL. Deterministic: every random field is seeded.
"""
import numpy as np
from PIL import Image, ImageFilter

T = 32          # final pixels per cell
SS = 8          # supersampling
P = T * SS      # working pixels per cell

LIGHT = np.array([-0.48, -0.62, 0.62])
LIGHT = LIGHT / np.linalg.norm(LIGHT)
HALF = (LIGHT + np.array([0, 0, 1.0]))
HALF = HALF / np.linalg.norm(HALF)


def rgb(hexstr):
    h = hexstr.lstrip("#")
    if len(h) == 3:
        h = "".join(ch * 2 for ch in h)
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], np.float32)


# --- noise -----------------------------------------------------------------------------
def _upsample(grid, h, w):
    """Smooth periodic upsampling of a small random grid to (h, w) — wraps at the edges."""
    gh, gw = grid.shape
    big = np.tile(grid, (3, 3)).astype(np.float32)
    im = Image.fromarray(big, mode="F").resize((gw * 3 * w // gw, gh * 3 * h // gh), Image.BICUBIC)
    a = np.asarray(im)
    return a[h:2 * h, w:2 * w]


def noise(h, w, cells, seed, period=None):
    """Tileable value noise with `cells` lattice points across the canvas width."""
    rng = np.random.default_rng(seed)
    gw = max(1, int(cells))
    gh = max(1, int(round(cells * h / max(1, w))))
    return _upsample(rng.random((gh, gw)), h, w) * 2 - 1


def fbm(h, w, base, seed, octaves=4, gain=0.5):
    out = np.zeros((h, w), np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        out += amp * noise(h, w, base * (2 ** o), seed + o * 101)
        tot += amp
        amp *= gain
    return out / tot


def _box(a, r, axis):
    if r < 1:
        return a
    pad = [(0, 0)] * a.ndim
    pad[axis] = (r + 1, r)
    c = np.cumsum(np.pad(a, pad, mode="edge"), axis=axis, dtype=np.float64)
    hi = np.take(c, np.arange(2 * r + 1, c.shape[axis]), axis=axis)
    lo = np.take(c, np.arange(0, c.shape[axis] - 2 * r - 1), axis=axis)
    return ((hi - lo) / (2 * r + 1)).astype(np.float32)


def blur(a, sigma_px):
    """Gaussian blur approximated by three box passes (numpy only, edge-clamped)."""
    if sigma_px <= 0.3:
        return a
    w = np.sqrt(12 * sigma_px * sigma_px / 3 + 1)
    r = max(1, int(round((w - 1) / 2)))
    out = a.astype(np.float32)
    for _ in range(3):
        out = _box(_box(out, r, 0), r, 1)
    return out


# --- canvas ------------------------------------------------------------------------------
class Canvas:
    def __init__(self, wc, hc, opaque=False, seed=1):
        self.wc, self.hc = wc, hc
        self.w, self.h = int(round(wc * P)), int(round(hc * P))
        self.col = np.zeros((self.h, self.w, 3), np.float32)
        self.hgt = np.zeros((self.h, self.w), np.float32)
        self.alpha = np.ones((self.h, self.w), np.float32) if opaque else np.zeros((self.h, self.w), np.float32)
        self.gloss = np.zeros((self.h, self.w), np.float32)
        self.emit = np.zeros((self.h, self.w), np.float32)
        self.opaque = opaque
        self.seed = seed
        ys, xs = np.mgrid[0:self.h, 0:self.w].astype(np.float32)
        self.x = (xs + 0.5) / P
        self.y = (ys + 0.5) / P

    # coverage of a rounded rectangle, anti-aliased; d = signed distance in cells
    def _rrect_sd(self, x0, y0, x1, y1, r):
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        hx, hy = (x1 - x0) / 2 - r, (y1 - y0) / 2 - r
        qx = np.abs(self.x - cx) - hx
        qy = np.abs(self.y - cy) - hy
        out = np.sqrt(np.maximum(qx, 0) ** 2 + np.maximum(qy, 0) ** 2)
        inside = np.minimum(np.maximum(qx, qy), 0)
        return out + inside - r

    def _ellipse_sd(self, cx, cy, rx, ry):
        k = np.sqrt(((self.x - cx) / rx) ** 2 + ((self.y - cy) / ry) ** 2)
        return (k - 1) * min(rx, ry)

    def paint(self, sd, z, mat, bevel=0.03, dome=0.0, base=None, gloss=None, emit=0.0, shape_mask=None):
        """Lay a surface where sd < 0: height z (+dome), soft bevel at the rim."""
        aa = 1.0 / P
        cov = np.clip(0.5 - sd / aa, 0, 1)
        if shape_mask is not None:
            cov = cov * shape_mask
        sel = cov > 0
        if not sel.any():
            return cov
        ys, xs = np.nonzero(sel)
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        c = cov[y0:y1, x0:x1]
        inner = np.clip(-sd[y0:y1, x0:x1] / max(bevel, 1e-4), 0, 1)
        prof = inner * inner * (3 - 2 * inner)
        top = z * (0.82 + 0.18 * prof) if bevel > 0 else np.full_like(c, z)
        if dome:
            top = top + dome * np.sqrt(np.clip(inner, 0, 1))
        b = self.hgt[y0:y1, x0:x1] if base is None else np.full_like(c, base)
        hnew = b * (1 - prof) + top * prof if bevel > 0 else top
        color, gl = mat(self.x[y0:y1, x0:x1], self.y[y0:y1, x0:x1], self.seed)
        sl = (slice(y0, y1), slice(x0, x1))
        self.col[sl] = self.col[sl] * (1 - c[..., None]) + color * c[..., None]
        self.hgt[sl] = self.hgt[sl] * (1 - c) + hnew * c
        self.alpha[sl] = np.maximum(self.alpha[sl], c)
        g = gl if gloss is None else gloss
        self.gloss[sl] = self.gloss[sl] * (1 - c) + g * c
        self.emit[sl] = self.emit[sl] * (1 - c) + emit * c
        return cov

    def rect(self, x0, y0, x1, y1, z, mat, r=0.02, bevel=0.03, **kw):
        return self.paint(self._rrect_sd(x0, y0, x1, y1, r), z, mat, bevel=bevel, **kw)

    def ellipse(self, cx, cy, rx, ry, z, mat, bevel=0.03, **kw):
        return self.paint(self._ellipse_sd(cx, cy, rx, ry), z, mat, bevel=bevel, **kw)

    def circle(self, cx, cy, r, z, mat, **kw):
        return self.ellipse(cx, cy, r, r, z, mat, **kw)

    def groove(self, x0, y0, x1, y1, depth=0.01, dark=0.75, r=0.0):
        """A seam or engraved line: lowers the surface and darkens it."""
        sd = self._rrect_sd(x0, y0, x1, y1, r)
        cov = np.clip(0.5 - sd * P, 0, 1)
        self.hgt -= depth * cov
        self.col *= (1 - (1 - dark) * cov)[..., None]

    def line(self, xa, ya, xb, yb, width, z, mat, **kw):
        dx, dy = xb - xa, yb - ya
        L2 = dx * dx + dy * dy + 1e-9
        t = np.clip(((self.x - xa) * dx + (self.y - ya) * dy) / L2, 0, 1)
        d = np.sqrt((self.x - xa - t * dx) ** 2 + (self.y - ya - t * dy) ** 2) - width / 2
        return self.paint(d, z, mat, **kw)

    # --- render -------------------------------------------------------------------------
    def render(self, shadow=True, shadow_strength=0.55, relief=7.0, ao=0.9):
        h = self.hgt
        gy, gx = np.gradient(h * relief * P / 32.0)
        n = np.stack([-gx, -gy, np.ones_like(h)], -1)
        n /= np.linalg.norm(n, axis=-1, keepdims=True)
        diff = np.clip(n @ LIGHT, 0, 1)
        flat = LIGHT[2]
        shade = (0.42 + 0.58 * diff) / (0.42 + 0.58 * flat)
        spec = self.gloss * np.clip(n @ HALF, 0, 1) ** 40 * 0.55
        # ambient occlusion: lower than the surroundings -> darker
        occl = np.clip((blur(h, 0.06 * P) - h) * 3.2, 0, 0.6) * ao
        # cast self-shadows along the light: something taller up-light darkens us
        cast = np.zeros_like(h)
        lx, ly = -LIGHT[0], -LIGHT[1]
        for step in (0.03, 0.06, 0.1, 0.15):
            dx, dy = int(round(-lx * step * P)), int(round(-ly * step * P))
            sh = np.roll(np.roll(h, dy, 0), dx, 1)
            cast = np.maximum(cast, np.clip((sh - h - step * 0.9) * 4.0, 0, 0.55))
        light = shade * (1 - occl) * (1 - cast * 0.8)
        col = self.col * light[..., None] + spec[..., None]
        col = col * (1 - self.emit[..., None]) + self.col * self.emit[..., None]
        col = np.clip(col, 0, 1)
        a = self.alpha.copy()
        if shadow and not self.opaque:
            # drop shadow down-right of the object, softened
            off = 0.06 * P
            sa = np.roll(np.roll(self.alpha * np.clip(self.hgt * 3 + 0.4, 0, 1), int(off), 0), int(off * 0.8), 1)
            sa = blur(sa, 0.05 * P) * shadow_strength
            out_a = a + sa * (1 - a)
            col = np.where(out_a[..., None] > 0, col * (a / np.maximum(out_a, 1e-6))[..., None], 0)
            a = out_a
        return col, a

    def image(self, **kw):
        """Downscaled RGBA PIL image (premultiplied resize: no dark fringes)."""
        col, a = self.render(**kw)
        pre = np.concatenate([col * a[..., None], a[..., None]], -1)
        im = Image.fromarray((np.clip(pre, 0, 1) * 255).astype(np.uint8), "RGBA")
        small = im.resize((self.w // SS, self.h // SS), Image.LANCZOS)
        arr = np.asarray(small).astype(np.float32) / 255
        al = arr[..., 3:4]
        rgbv = np.where(al > 0.004, arr[..., :3] / np.maximum(al, 1e-6), 0)
        out = np.concatenate([np.clip(rgbv, 0, 1), al], -1)
        img = Image.fromarray((out * 255 + 0.5).astype(np.uint8), "RGBA")
        return img.filter(ImageFilter.UnsharpMask(radius=0.7, percent=45, threshold=1))


# --- materials -----------------------------------------------------------------------------
# A material: f(x, y, seed) -> (rgb array (h, w, 3), gloss array or float)
def _shape(x):
    return x.shape


def solid(color, var=0.035, scale=6, gloss=0.08):
    c = np.asarray(color, np.float32)

    def f(x, y, seed):
        n = _cell_noise(x, y, scale, seed + 7) * var
        return np.clip(c[None, None, :] * (1 + n[..., None]), 0, 1), gloss
    return f


def _cell_noise(x, y, scale, seed):
    # cheap smooth noise in world coordinates (periodic per cell so tiles join)
    k = scale * 2 * np.pi
    s = seed * 0.37
    return (np.sin(x * k + s) * np.sin(y * k * 1.13 + s * 1.7) * 0.5
            + np.sin((x + y) * k * 2.07 + s * 2.3) * 0.25
            + np.sin((x - y * 0.7) * k * 4.11 + s) * 0.25)


def grain_field(x, y, seed, freq=22, warp=0.8, angle=0.0):
    ca, sa = np.cos(angle), np.sin(angle)
    u = x * ca + y * sa
    v = -x * sa + y * ca
    w = (_cell_noise(u * 0.7, v * 3.0, 1.0, seed) * warp + _cell_noise(u * 3.1, v * 0.4, 1.0, seed + 5) * 0.3)
    rings = np.sin((v + w * 0.06) * freq * 2 * np.pi)
    fine = _cell_noise(u * 9, v * 40, 1.0, seed + 11)
    return rings * 0.55 + fine * 0.25


def wood(color, angle=0.0, freq=20, contrast=0.16, gloss=0.18):
    c = np.asarray(color, np.float32)

    def f(x, y, seed):
        g = grain_field(x, y, seed, freq, angle=angle)
        tint = 1 + g * contrast
        out = c[None, None, :] * tint[..., None]
        out[..., 2] *= 0.96
        return np.clip(out, 0, 1), gloss
    return f


def fabric(color, scale=40, contrast=0.07, gloss=0.02):
    c = np.asarray(color, np.float32)

    def f(x, y, seed):
        weave = (np.sin(x * scale * 2 * np.pi) * np.sin(y * scale * 2 * np.pi)) * 0.5
        mott = _cell_noise(x, y, 3, seed) * 0.5 + _cell_noise(x, y, 11, seed + 3) * 0.3
        tint = 1 + weave * contrast * 0.5 + mott * contrast
        return np.clip(c[None, None, :] * tint[..., None], 0, 1), gloss
    return f


def metal(color, brushed=0.0, contrast=0.05, gloss=0.55):
    c = np.asarray(color, np.float32)

    def f(x, y, seed):
        if brushed == 0:
            s = _cell_noise(x * 2, y * 70, 1, seed)
        else:
            s = _cell_noise(x * 70, y * 2, 1, seed)
        tint = 1 + s * contrast + _cell_noise(x, y, 5, seed + 9) * contrast * 0.6
        return np.clip(c[None, None, :] * tint[..., None], 0, 1), gloss
    return f


def painted(color, contrast=0.03, gloss=0.28):
    return solid(color, var=contrast, scale=5, gloss=gloss)


def plastic(color, gloss=0.35):
    return solid(color, var=0.02, scale=4, gloss=gloss)


def ceramic(color=(0.93, 0.93, 0.91), gloss=0.75):
    return solid(color, var=0.012, scale=3, gloss=gloss)


def concrete(color, contrast=0.12, pores=0.08, gloss=0.04):
    c = np.asarray(color, np.float32)

    def f(x, y, seed):
        n = _cell_noise(x, y, 2, seed) * 0.5 + _cell_noise(x, y, 7, seed + 1) * 0.3 + _cell_noise(x, y, 23, seed + 2) * 0.2
        p = np.clip(_cell_noise(x, y, 61, seed + 3) - 0.75, 0, 1) * 4
        tint = 1 + n * contrast - p * pores
        return np.clip(c[None, None, :] * tint[..., None], 0, 1), gloss
    return f


def screen(color, lines=True):
    c = np.asarray(color, np.float32)

    def f(x, y, seed):
        scan = 1 - 0.08 * (np.sin(y * 180 * np.pi) > 0.6)
        glow = 1 + _cell_noise(x, y, 2, seed) * 0.08
        return np.clip(c[None, None, :] * (scan * glow)[..., None], 0, 1), 0.6
    return f


def glass(color=(0.62, 0.74, 0.80)):
    return solid(color, var=0.03, scale=2, gloss=0.9)


# --- composites for autotile sheets ---------------------------------------------------------
def slice_cell(img, col, row):
    return img.crop((col * T, row * T, col * T + T, row * T + T))


def sheet_from(draw, opaque=False, seed=1, **render):
    """16-tile autotile sheet (mask = N1 + E2 + S4 + W8) cut from renders of the object at
    1x1, 3x1, 1x3 and 3x3 cells. draw(canvas, w, h) models an object filling w x h cells;
    its middle cells must repeat (per-cell periodic) so neighbouring tiles join."""
    renders = {}
    for w, h in ((1, 1), (3, 1), (1, 3), (3, 3)):
        cv = Canvas(w, h, opaque=opaque, seed=seed)
        draw(cv, w, h)
        renders[(w, h)] = cv.image(**render)
    out = Image.new("RGBA", (T * 4, T * 4), (0, 0, 0, 0))
    for mask in range(16):
        n, e, s, wst = mask & 1, mask & 2, mask & 4, mask & 8
        w = 3 if (e or wst) else 1
        h = 3 if (n or s) else 1
        col = 0 if w == 1 else (0 if (e and not wst) else (2 if (wst and not e) else 1))
        row = 0 if h == 1 else (0 if (s and not n) else (2 if (n and not s) else 1))
        out.paste(slice_cell(renders[(w, h)], col, row), ((mask % 4) * T, (mask // 4) * T))
    return out


# --- samples ---------------------------------------------------------------------------------
def sample_of(img, sheet):
    """The marked-up template users paint over: magenta box per tile; for a 16-tile sheet,
    white bars on the sides where that tile has a neighbour."""
    s = img.copy().convert("RGBA")
    px = s.load()
    w, h = s.size
    mag = (255, 0, 255, 255)
    for ty in range(0, h, T):
        for tx in range(0, w, T):
            for k in range(T):
                for (xx, yy) in ((tx + k, ty), (tx + k, ty + T - 1), (tx, ty + k), (tx + T - 1, ty + k)):
                    if xx < w and yy < h:
                        px[xx, yy] = mag
            if sheet and w == T * 4:
                mask = (ty // T) * 4 + (tx // T)
                for side in range(4):
                    if not mask & (1 << side):
                        continue
                    for k in range(T // 3, T - T // 3):
                        pos = [(tx + k, ty + 2), (tx + T - 3, ty + k), (tx + k, ty + T - 3), (tx + 2, ty + k)][side]
                        px[pos] = (255, 255, 255, 255)
    return s
