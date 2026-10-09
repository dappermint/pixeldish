#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 look;    // shape, dither, pixelSize, colors
    float4 tune;    // warp, contrast, grain, vignette
    float4 misc;    // seed, invert, time, spread
    float4 view;    // resX, resY, zoom, isPhoto
    float4 pal[5];
};

// ---------------------------------------------------------------- noise

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1.0, 0.0)), u.x),
               mix(hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)), u.x),
               u.y);
}

static inline float fbmN(float2 p, int octaves) {
    float sum = 0.0;
    float amp = 0.5;
    for (int i = 0; i < octaves; ++i) {
        sum += vnoise(p) * amp;
        p = float2(p.x * 1.6 - p.y * 1.2, p.x * 1.2 + p.y * 1.6);
        amp *= 0.5;
    }
    return sum;
}
static inline float fbm5(float2 p) { return fbmN(p, 5); }
// displacement only: the top two octaves move pixels by less than one dither cell
static inline float fbm3(float2 p) { return fbmN(p, 3); }

// moves at unit speed round a circle of radius r: bounded, so a wallpaper left
// running for days never pans the noise into float-precision mush
static inline float2 loop(float r, float t) { return r * float2(cos(t / r), sin(t / r)); }
static inline float sstep(float x) { float c = saturate(x); return c * c * (3.0 - 2.0 * c); }
static inline float bayer2(float2 a) { a = floor(a); return fract(a.x * 0.5 + a.y * a.y * 0.75); }
static inline float2x2 rot(float a) { float c = cos(a), s = sin(a); return float2x2(c, s, -s, c); }

// ---------------------------------------------------------------- shapes

static float fieldOf(int shape, float2 uv, float seed, float warp, float time)
{
    float2 g = fract(float2(seed * 0.7137, seed * 0.3711)) * 64.0;
    // g only pans the noise; these make seeds differ in scale, handedness and drift
    float sk = seed * 0.01;
    float4 k = float4(hash21(float2(sk, 1.7)), hash21(float2(sk, 9.2)),
                      hash21(float2(sk, 3.1)), hash21(float2(sk, 5.5)));
    float hand = k.y < 0.5 ? -1.0 : 1.0;
    float2x2 drift = rot(k.z * 6.2831853);

    switch (shape) {
    case 0: {   // drift: domain-warped fbm, the noise pushed along its own gradient
        float2 p = g + uv * 1.2 + drift * loop(6.0, time * 0.15);
        float2 q = float2(fbm3(p), fbm3(p + float2(5.2, 1.3)));
        return saturate((fbm5(p + (warp * 2.5 + 0.5) * q) - 0.5) * 1.8 + 0.5);
    }
    case 1: {   // shepard: four drifting colour stops blended like a gradient mesh
        float2 w = (float2(fbm3(g + uv), fbm3(g + uv + 7.1)) - 0.5) * warp;
        float num = 0.0, den = 0.0;
        for (int i = 0; i < 4; ++i) {
            float fi = float(i);
            float a = fi * 1.7 + g.x + hand * time * (0.11 + 0.04 * fi);
            float2 d = uv + w - float2(0.9 * sin(a), 0.55 * cos(a * 1.3 + fi + g.y));
            float wt = 1.0 / (dot(d, d) * dot(d, d) + 0.002);
            num += wt * fi * 0.33333334;
            den += wt;
        }
        return num / den;
    }
    case 2: {   // sines: demoscene sine sum
        float2 p = g + uv * mix(3.0, 5.0, k.x);
        float2 c = p + 2.0 * float2(sin(time * 0.3), cos(time * 0.4));
        float v = sin(p.x + time) + sin(p.y * 1.7 - time * 1.4)
                + sin((p.x + p.y) * 0.6 + time * 0.5) + sin(length(c) * 1.5 - time);
        return 0.5 + 0.18 * v + (fbm3(p * 0.5) - 0.5) * warp;
    }
    case 3: {   // fringe: three point sources interfering
        float2 p = uv + (float2(fbm3(g + uv * 1.5), fbm3(g + uv * 1.5 + 3.3)) - 0.5) * warp * 0.5;
        float v = 0.0;
        for (int i = 0; i < 3; ++i) {
            float fi = float(i);
            float2 s = (float2(hash21(g + fi), hash21(g + fi + 9.1)) - 0.5) * 1.2
                     + 0.2 * float2(sin(time * (0.15 + 0.05 * fi) + fi), cos(time * 0.13 + fi * 2.0));
            v += sin(length(p - s) * mix(9.0, 15.0, hash21(g + fi * 3.7)) - time * 1.8);
        }
        return 0.5 + 0.22 * v;
    }
    case 4: {   // curtain: a wavering curtain with vertical rays, fading upward
        float x = uv.x * 1.3 + g.x;
        float bend = fbm3(float2(x * 0.6, time * 0.05 + g.y));
        float dy = uv.y - (bend - 0.5) * 1.2 - 0.1 * sin(x * 2.0 + time * 0.2);
        float rays = fbm3(float2(x * 6.0 + (bend - 0.5) * warp * 6.0, time * 0.1));
        // screen y grows downward: a hard lower hem, rays fading slowly upward
        float fall = dy > 0.0 ? exp(-dy * dy * 60.0) : exp(dy * 1.8);
        float streak = dy > 0.0 ? 1.0 : rays * rays * 2.2;
        return saturate(fall * (0.35 + 0.9 * rays) * streak + 0.04);
    }
    case 5: {   // voronoi: dark network, each cell glowing faintly round its seed
        float2 p = g + uv * mix(2.5, 4.0, k.x);
        float2 cell = floor(p), f = fract(p);
        float d0 = 8.0, d1 = 8.0, id = 0.0;
        for (int j = -1; j <= 1; ++j) {
            for (int i = -1; i <= 1; ++i) {
                float2 o = float2(i, j);
                float h = hash21(cell + o);
                float2 pt = o + 0.5 + 0.4 * sin(time * 0.4 + 6.2831853 * float2(h, hash21(cell + o + 31.7))) - f;
                float d = dot(pt, pt);
                if (d < d0) { d1 = d0; d0 = d; id = h; } else if (d < d1) { d1 = d; }
            }
        }
        // F2-F1 is 0 on the borders and peaks at the seed; the 1.5 power keeps
        // most of the screen dark, warp brightens the cores
        float core = saturate((sqrt(d1) - sqrt(d0)) * (0.6 + 0.9 * warp));
        return core * sqrt(core) * (0.8 + 0.2 * id);
    }
    case 6: {   // contour: contour map, fixed-width lines over the height
        float2 p = g + uv * 1.3 + drift * loop(5.0, time * 0.05);
        p += (fbm3(p * 2.0) - 0.5) * warp;
        float n = fbmN(p, 4);
        float x = n * mix(8.0, 12.0, k.x);
        float line = 1.0 - saturate(min(fract(x), 1.0 - fract(x)) / (fwidth(x) * 1.2));
        return saturate((n - 0.22) * 1.8) * (1.0 - 0.8 * line);
    }
    case 7: {   // vortex: marbled stripes wound into a vortex, tighter toward the eye
        float2 p = uv - (fract(g * 0.37) - 0.5) * 0.6;
        float r = length(p);
        float a = hand * ((warp * 5.0 + 1.0) * exp(-r * 1.6) + time * 0.12);
        float2 s = rot(a) * p;
        float n = fbm5(s * 1.3 + g);
        return 0.5 + 0.5 * sin(s.x * mix(5.0, 9.0, k.x) + n * 5.0);
    }
    case 8: {   // sweep: rings rolling out from a ping under a fading radar sweep
        float2 p = uv - (fract(g * 0.53) - 0.5) * 0.7;
        float r = length(p) + (fbm3(p * 1.5 + g) - 0.5) * warp * 0.5;
        float trail = fract((hand * atan2(p.y, p.x) - time * 0.6) * 0.15915494);
        float ring = 0.5 + 0.5 * cos((r * mix(4.5, 8.0, k.x) - time * 0.5) * 6.2831853);
        return saturate(trail * trail * 0.75 + ring * (0.45 - 0.2 * trail));
    }
    case 9: {   // glitch: macroblocks stuck on stale motion vectors, smeared sideways
        float beat = floor(time * 1.5);
        float bs = exp2(floor(mix(3.0, 5.0, hash21(floor(uv * 4.0) + beat))));
        float2 blk = floor(uv * bs);
        float2 h = float2(hash21(blk + beat), hash21(blk + beat + 5.1)) - 0.5;
        float2 q = uv + drift * loop(4.0, time * 0.1);
        // corruption comes in horizontal bands, like a lost run of P-frames
        bool band = hash21(float2(floor(blk.y / 3.0), beat)) > 0.75 - warp * 0.4;
        if (band && hash21(blk + beat + 2.2) > 0.3) {
            q += h * 0.35;                                   // stale motion vector
            if (h.y > 0.0) q.x = (blk.x + h.x) / bs;         // pixels smeared along the row
        }
        return saturate((fbm5(g + q * 1.4) - 0.5) * 2.0 + 0.5);
    }
    case 10: {  // twill: 2/2 twill, rounded threads, cloth rippling under warp
        float2 p = g + uv * mix(7.0, 12.0, k.x) + drift * loop(3.0, time * 0.3);
        p += warp * 0.6 * float2(sin(p.y * 0.35 + time * 0.3), sin(p.x * 0.3 + time * 0.25));
        float2 cell = floor(p);
        float2 f = fract(p) - 0.5;
        float d = cell.x + hand * cell.y;
        bool up = d - 4.0 * floor(d * 0.25) < 2.0;
        float2 v = cos(f * 3.1415927);
        float top = up ? v.x : v.y;
        float along = up ? v.y : v.x;
        float tint = hash21(up ? float2(cell.x, 1.0) : float2(cell.y, 7.0)) * 0.15;
        return top * (0.4 + 0.6 * along) * (up ? 0.85 : 0.65) + tint;
    }
    case 11: {  // belts: factory floor, transport lines between rows of machines
        float2 p = (k.w < 0.5 ? uv.yx : uv) * mix(7.0, 10.0, k.x) + g;
        float row = floor(p.y);
        float fy = fract(p.y) - 0.5;
        float tile = 0.1 + 0.05 * hash21(floor(p)) - 0.05 * step(0.47, abs(fract(p.x) - 0.5));
        if (hash21(float2(row, 0.5)) > 0.55 + 0.3 * warp) {
            // machine row: 3x1 housings with a spinning bright hub
            float2 m = float2(fract(p.x / 3.0) - 0.5, fy);
            float idx = floor(p.x / 3.0);
            if (hash21(float2(row, idx)) < 0.4 || max(abs(m.x) * 3.0, abs(fy)) > 0.44) return tile;
            float2 hub = float2(m.x * 3.0, fy);
            float r = length(hub);
            float teeth = step(0.5, fract(atan2(hub.y, hub.x) * 1.2732395 + time * hand));
            if (r < 0.32) return r < 0.1 ? 0.95 : 0.55 + 0.3 * teeth * step(0.22, r);
            return 0.35;
        }
        float dir = hash21(float2(row, 1.7)) < 0.5 ? -1.0 : 1.0;
        float along = p.x * dir - time * (1.0 + floor(hash21(float2(row, 4.4)) * 3.0)) * 0.3;
        if (abs(fy) > 0.42) return 0.22;
        float chev = step(fract(along * 2.0 - abs(fy) * 1.6), 0.28);
        float lane = fy > 0.0 ? 1.0 : 0.0;
        float slot = floor(along * 1.5);
        float2 it = float2((fract(along * 1.5) - 0.5) / 1.5, abs(fy) - 0.2);
        float has = step(0.45, hash21(float2(slot, lane + row * 3.0)));
        if (has > 0.5 && length(it) < 0.13)
            return hash21(float2(slot, lane + row * 5.0)) < 0.5 ? 0.78 : 0.97;
        return 0.38 + 0.18 * chev;
    }
    case 12: {  // circuit: two copper layers of straight runs, pads, sparse signals
        float2 p = g + uv * mix(9.0, 14.0, k.x);
        float v = 0.08 + 0.17 * fbm3(p * 0.3);
        for (int l = 0; l < 2; ++l) {
            float2 q = l == 0 ? p : p.yx + 0.5;
            float row = floor(q.y);
            float fb = fract(q.y) - 0.5;
            float len = 2.0 + floor(hash21(float2(row, l)) * 5.0);
            float x = q.x + hash21(float2(row, 9.0 + l)) * 13.0;
            float seg = floor(x / len);
            float sa = x - seg * len;
            float2 id = float2(row * 2.0 + l, seg);
            if (hash21(id) > 0.35 + 0.3 * warp) continue;
            float end = min(sa - 0.5, len - 0.5 - sa);
            float pad = length(float2(min(abs(sa - 0.5), abs(sa - len + 0.5)), fb));
            // the back layer shows through dimmer, so crossings read as two layers
            float layer = l == 0 ? 1.0 : 0.6;
            if (pad < 0.2) { v = pad < 0.07 ? 0.05 : 0.72 * layer; continue; }
            if (end < 0.0 || abs(fb) > 0.07) continue;
            float lit = step(hash21(id + 4.2), 0.3) * layer;
            float head = fract(sa / len - time * (0.2 + 0.4 * hash21(id + 1.1)) * hand);
            v = max(v, 0.45 * layer + lit * 0.55 * head * head * head);
        }
        return v;
    }
    case 13: {  // julia: the set for c riding round the cardioid's favourite circle
        float2 z = rot(k.z * 6.2831853) * uv * 1.5;
        float a = k.w * 6.2831853 + hand * time * 0.03;
        float2 c = (0.7885 + (warp - 0.5) * 0.04) * float2(cos(a), sin(a));
        float trap = 8.0, m2 = 0.0;
        int i = 0;
        for (; i < 64; ++i) {
            z = float2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
            m2 = dot(z, z);
            trap = min(trap, abs(z.x * z.y));
            if (m2 > 256.0) break;
        }
        if (i == 64) return saturate(sqrt(trap) * 1.5) * 0.4;
        // escape counts pile up near zero, the fourth root spreads them over the ramp
        return sqrt(sqrt(saturate((float(i) - log2(log2(m2)) + 2.0) / 40.0)));
    }
    default: {  // kali: the kaliset fold, abs(p)/dot(p,p) - c, iterated
        float2 p = rot(k.z * 6.2831853) * uv * 0.8 + drift * loop(1.5, time * 0.02);
        float2 c = float2(0.55, 0.6) + (k.xy - 0.5) * 0.2 + warp * 0.075;
        float acc = 0.0, prev = 0.0;
        for (int i = 0; i < 10; ++i) {
            p = abs(p) / max(dot(p, p), 1e-4) - c;
            float l = length(p);
            acc += exp(-abs(l - prev) * 3.0);
            prev = l;
        }
        return saturate((acc - 1.0) * 0.3);
    }
    }
}

// ---------------------------------------------------------------- dither

static inline float3 ramp(constant Uniforms &u, float t, float colors) {
    float f = saturate(t) * (colors - 1.0);
    int i0 = max(min(int(f), int(colors) - 2), 0);
    return mix(u.pal[i0].rgb, u.pal[i0 + 1].rgb, f - float(i0));
}

// Every dither quantises the field onto the palette, so anything that wants to
// darken or roughen the picture has to move the *field* before that happens.
// Doing it to the colour afterwards invents colours the palette does not have.
static float3 shade(int dither, float field, float2 uv, float pixelSize, float colors,
                    constant Uniforms &u, texture2d<float> atlas)
{
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float levels = max(colors, 2.0) - 1.0;
    float2 cell = floor(uv / pixelSize);
    float2 cuv = fract(uv / pixelSize);

    if (dither == 8) {          // ascii: glyph density is the shade, palette stays two-tone
        float lvl = min(floor(levels * field + 0.5), levels);
        float3 fg = ramp(u, lvl / levels, colors);
        float gi = floor(saturate(lvl / levels) * 15.0 + 0.5);
        float au = ((cuv.x - 0.5) * 0.94 + 0.5 + gi) * 0.0625;
        float glyph = atlas.sample(smp, float2(au, cuv.y)).r;
        return glyph > 0.5 ? fg : u.pal[0].rgb;
    }
    if (dither == 9) {          // benday: three rotated dot lattices. Distance to
                                // the nearest rotated lattice point gives a real
                                // halftone ramp; the obvious concentric version put
                                // 84% of pixels at one threshold and collapsed.
                                // Mixing screens per channel would invent colours,
                                // so the screens only build the threshold
        // max, not min: the nearest-dot distance is below 0.5 for 80% of pixels,
        // so a min screen collapses every 2-colour render to one tone
        float2 d = cuv - 0.5;
        float th = 0.0;
        float ang[3] = {M_PI_F / 12.0, M_PI_F / 4.0, 5.0 * M_PI_F / 12.0};   // 15, 45, 75 degrees
        for (int i = 0; i < 3; ++i) {
            float ca = cos(ang[i]), sa = sin(ang[i]);
            float2 r = float2(d.x * ca - d.y * sa, d.x * sa + d.y * ca) * 4.0;
            float2 f = r - round(r);
            th = max(th, min(length(f) / 0.7071, 1.0));
        }
        float qz = min(floor(th + levels * field), levels) / levels;
        return ramp(u, qz, colors);
    }

    float phi = -1.0;
    switch (dither) {
    case 1: phi = 0.5; break;
    case 2: phi = bayer2(cell * 0.5) * 0.25 + bayer2(cell) + 0.03125; break;
    case 3: phi = bayer2(cell) + 0.0078125
               + 0.25 * (bayer2(cell * 0.5) + 0.25 * bayer2(cell * 0.25)); break;
    case 4: phi = fract(52.9829189 * fract(dot(cell, float2(0.06711056, 0.00583715)))); break;  // IGN
    // 1 - 2d^2: dot area grows linearly with the threshold, so every level gets a fair share
    case 5: { float2 d = cuv - 0.5; phi = 1.0 - 2.0 * dot(d, d); break; }
    case 6: phi = 1.0 - abs(cuv.y - 0.5) * 2.0; break;
    case 7: phi = 1.0 - (abs(cuv.x - 0.5) + abs(cuv.y - 0.5)); break;
    // bayer 2 and 16: the same recursion as 4 and 8, one level shallower or deeper
    case 10: phi = bayer2(cell) + 0.125; break;
    case 11: phi = bayer2(cell) + 0.001953125
                + 0.25 * (bayer2(cell * 0.5) + 0.25 * (bayer2(cell * 0.25) + 0.25 * bayer2(cell * 0.125))); break;
    // R2: lattice from the plastic constant (1/g, 1/g^2), the lowest-discrepancy 2D sequence
    // known, so noise-like thresholds without the clumps of hashed noise
    case 12: phi = fract(0.5 + dot(cell, float2(0.75487767, 0.56984029))); break;
    default: phi = -1.0; break;
    }

    float qz = phi < 0.0 ? field : min(floor(phi + levels * field), levels) / levels;
    return ramp(u, qz, colors);
}

// ---------------------------------------------------------------- entry

struct VOut { float4 pos [[position]]; };

vertex VOut vmain(uint id [[vertex_id]]) {
    VOut o;
    o.pos = float4(float((id << 1) & 2) * 2.0 - 1.0, float(id & 2) * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

fragment float4 fmain(float4 pos [[position]],
                      constant Uniforms &u [[buffer(0)]],
                      texture2d<float> photo [[texture(0)]],
                      texture2d<float> atlas [[texture(1)]])
{
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 res = u.view.xy;
    float2 uv = pos.xy;
    float2 centered = (uv - res * 0.5) * (1.95 / max(u.view.z, 0.01)) / res.y;

    float field;
    if (u.view.w > 0.5) {
        field = dot(photo.sample(smp, uv / res).rgb, float3(0.299, 0.587, 0.114));
    } else {
        field = fieldOf(int(u.look.x), centered, u.misc.x, u.tune.x, u.misc.z);
    }
    // contrast, then spread: several shapes only reach the middle of the range
    // (Drift covers 0.21..0.83), so without this the end palette entries never
    // appear. spread=0 leaves the field alone, which some shapes want
    field = saturate((field - 0.5) * u.tune.y + 0.5);
    if (u.misc.w > 0.0) field = saturate((field - u.misc.w) / max(1.0 - 2.0 * u.misc.w, 0.01));
    if (u.misc.y > 0.5) field = 1.0 - field;      // invert before quantising

    float2 nrm = uv / res;
    float ar = res.x / res.y;
    float2 ec = float2(ar, 1.0) * (nrm - 0.5);
    float vig = 1.0 - u.tune.w * sstep((length(ec) - 0.35) * 1.3333334);
    field *= vig;

    // grain is fine relative to the dither cell, so it breaks up the flat
    // quantised areas without turning the palette into noise
    if (u.tune.z > 0.0) {
        // tied to the seed, not the clock: reseeding it per frame read as TV static
        float2 q = fract(uv * float2(0.7548777, 0.5698403) + fract(u.misc.x) * 137.0);
        q += dot(q, q + 45.32);
        field += (fract(q.x * q.y) - 0.5) * u.tune.z;
    }
    field = saturate(field);

    float3 c = shade(int(u.look.y), field, uv, u.look.z, u.look.w, u, atlas);
    return float4(c, 1.0);
}
