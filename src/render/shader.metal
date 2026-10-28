#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 look;    // shape, dither, pixelSize, colors
    float4 tune;    // warp, contrast, grain, vignette
    float4 misc;    // seed, invert, time, spread
    float4 view;    // resX, resY, zoom, isPhoto
    float4 pal[5];
    float4 shp[2];  // per-shape knobs, see kShapeParams
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

// ---------------------------------------------------------------- black holes
// geometric units of the hole's mass, G = c = M = 1

static float iscoR(float a) {
    float z1 = 1.0 + pow(1.0 - a * a, 1.0 / 3.0) * (pow(1.0 + a, 1.0 / 3.0) + pow(1.0 - a, 1.0 / 3.0));
    float z2 = sqrt(3.0 * a * a + z1 * z1);
    return 3.0 + z2 - sqrt((3.0 - z1) * (3.0 + z1 + 2.0 * z2));
}

// Page-Thorne thin disk flux up to a constant: zero at the ISCO, r^-3 far out
static float ptFlux(float r, float a) {
    a = max(a, 1e-3);   // the x2 term is 0/0 at a = 0, its limit is 0
    float x = sqrt(r), x0 = sqrt(iscoR(a)), c = acos(a) / 3.0;
    float3 xr = 2.0 * float3(cos(c - M_PI_F / 3.0), cos(c + M_PI_F / 3.0), -cos(c));
    float s = x - x0 - 1.5 * a * log(x / x0);
    for (int i = 0; i < 3; ++i) {
        float xi = xr[i], xj = xr[(i + 1) % 3], xk = xr[(i + 2) % 3];
        s -= 3.0 * (xi - a) * (xi - a) / (xi * (xi - xj) * (xi - xk)) * log((x - xi) / (x0 - xi));
    }
    return max(s, 0.0) / (r * r * (x * x * x - 3.0 * x + 2.0 * a));
}

// redshift of a photon with angular momentum lam leaving a prograde circular orbit
static float diskShift(float r, float lam, float a) {
    float s = sqrt(r), om = 1.0 / (r * s + a);
    float ut = (r * s + a) / sqrt(r * s * max(r * s - 3.0 * s + 2.0 * a, 1e-4));
    return 1.0 / (ut * (1.0 - om * lam));
}

// observed disk brightness: Page-Thorne flux times g^4, so whatever the gas does,
// the side turning toward us flares. time is in M, the disk's own clock
static float diskLight(float r, float lam, float phi, float a, float time, float2 g, float turb, float temp) {
    float om = 1.0 / (r * sqrt(r) + a), tM = time * 25.0;
    // turbulence: noise on a small circle that slides through the field with r, so
    // features run along the orbit and change fast across it, with no seam in phi.
    // Two layers crossfade on a 120M cycle, so the shear never winds them finer than a pixel
    float c = tM / 120.0, n = 0.0;
    for (int i = 0; i < 2; ++i) {
        float f = fract(c + 0.5 * float(i)), ang = phi - om * f * 120.0;
        float2 q = g + floor(c + 0.5 * float(i)) * 13.1 + r * float2(1.6, 0.9);
        n += (1.0 - abs(2.0 * f - 1.0)) * fbm5(q + 1.3 * float2(cos(ang), sin(ang)));
    }
    float gas = mix(1.0, 0.15 + 1.7 * sstep((n - 0.5) * 2.5 + 0.5), saturate(1.6 * turb));
    // hot spots ride their own orbits, rigid so they never wind up, and flare and fade over a life
    float ri = iscoR(a), hot = 0.0;
    for (int j = 0; j < 3; ++j) {
        float life = tM / 400.0 + float(j) / 3.0, k = floor(life);
        float2 h = float2(hash21(g + float2(k, float(j))), hash21(g + float2(float(j), k) + 4.7));
        float rs = mix(1.15 * ri, 3.0 * ri + 4.0, h.x), ps = h.y * 6.2831853 + tM / (rs * sqrt(rs) + a);
        float2 d = r * float2(cos(phi), sin(phi)) - rs * float2(cos(ps), sin(ps));
        hot += sin(fract(life) * M_PI_F) * exp(-dot(d, d) / (0.25 * rs));
    }
    float flicker = 1.0 + 0.3 * turb * (vnoise(float2(tM * 0.02, g.x)) - 0.5);
    float e = pow(diskShift(r, lam, a) * temp, 4.0) * ptFlux(r, a) / ptFlux(1.36 * ri, a);
    // flux falls as r^-3, so a gamma keeps the outer disk on screen
    return 1.0 - exp(-2.0 * pow(e * gas * (1.0 + 3.0 * turb * hot) * flicker, 0.45));
}

static float sky(float3 d, float2 g) {
    float neb = fbm3(g + d.xy * 2.5 + d.z * float2(1.9, -1.3));
    float3 c = d * 80.0;
    float h = hash21(floor(c).xy + floor(c).z * 17.31 + g);
    float star = h > 0.96 ? (h - 0.96) * 25.0 * saturate(1.0 - 2.5 * length(fract(c) - 0.5)) : 0.0;
    return 0.02 + 0.2 * sstep((neb - 0.35) * 2.5) + star;
}

struct Ray { int kind; float r, phi, lam; float3 dir; };   // kind: 0 fell in, 1 hit the disk, 2 escaped

// a Kerr null geodesic traced back from a distant observer at inclination inc
// through Bardeen's image plane point ab. In Mino time r and theta decouple, so
// velocity Verlet steps each like a 1D particle: u = 1/r obeys u'' = U'(u)/2 for
// a polynomial U, and starts at exactly 0, so there is no far-field cut. The sky
// direction n moves as n'' = -w2 n - a^2 ((1 + 2z^2) n.xy, 2z^3), which is
// mu'' = Theta'(mu)/2 with the lam / sin^2 term folded in, plus frame dragging
// turning it about the spin axis. Unlike phi it has no pole to blow up at
static Ray kerrRay(float a, float inc, float2 ab, float rin, float rout) {
    float lam = -ab.x * sin(inc);
    float q = ab.y * ab.y + (ab.x * ab.x - a * a) * cos(inc) * cos(inc);
    float kk = (lam - a) * (lam - a) + q, w2 = q + lam * lam - a * a, aq = a * a * q;
    float uh = 1.0 / (1.01 * (1.0 + sqrt(max(1.0 - a * a, 0.0))));
    Ray o = {0, 0.0, 0.0, lam, float3(0.0)};
    // forward in time the photon leaves for infinity at u' = -1; we step backward
    float u = 0.0, vu = -1.0;
    float3 n = float3(sin(inc), 0.0, cos(inc));
    float3 vn = -(ab.x * float3(0.0, 1.0, 0.0) + ab.y * float3(-cos(inc), 0.0, sin(inc)));
    float h = -0.12 / (sqrt(max(w2, 0.0)) + 2.0);
    for (int i = 0; i < 320; ++i) {
        float vu2 = vu + 0.5 * h * (u * (-w2 + u * (3.0 * kk - 2.0 * aq * u)));
        float3 vn2 = vn - 0.5 * h * (w2 * n + a * a * float3((1.0 + 2.0 * n.z * n.z) * n.xy, 2.0 * n.z * n.z * n.z));
        float un = u + h * vu2, um = 0.5 * (u + un);
        float3 nn = normalize(n + h * vn2);
        float2x2 drag = rot(h * a * um * (2.0 - a * lam * um) / (1.0 - 2.0 * um + a * a * um * um));
        nn.xy = drag * nn.xy;
        vn2.xy = drag * vn2.xy;
        vu = vu2 + 0.5 * h * (un * (-w2 + un * (3.0 * kk - 2.0 * aq * un)));
        vn = vn2 - 0.5 * h * (w2 * nn + a * a * float3((1.0 + 2.0 * nn.z * nn.z) * nn.xy, 2.0 * nn.z * nn.z * nn.z));
        vn -= dot(vn, nn) * nn;
        if (n.z * nn.z < 0.0) {
            float f = n.z / (n.z - nn.z), rc = 1.0 / max(mix(u, un, f), 1e-6);
            float3 c = mix(n, nn, f);
            if (rc > rin && rc < rout) { o.kind = 1; o.r = rc; o.phi = atan2(c.y, c.x); return o; }
        }
        u = un;
        n = nn;
        if (u > uh) return o;
        if (u < 0.0) { o.kind = 2; o.dir = n; return o; }
    }
    return o;   // still circling the photon sphere: as good as fallen in
}

// the seed's noise pan and handedness; fieldOf and kerrTrace must agree on both
static inline float2 seedPan(float seed) { return fract(float2(seed * 0.7137, seed * 0.3711)) * 64.0; }
static inline float seedHand(float seed) { return hash21(float2(seed * 0.01, 9.2)) < 0.5 ? -1.0 : 1.0; }

// a heavier hole is bigger on screen and its gas orbits slower, both linear in M
static inline float2 kerrAB(float2 uv, float hand, float m) { return float2(hand * uv.x, -uv.y) * 15.0 / m; }

// the clock-free half of Kerr, which the renderer caches per pixel and redoes only
// when a knob moves: a disk hit as (r, phi), any other ray as (-field, 0), since
// one that fell in or escaped looks the same every frame
static float2 kerrTrace(float2 uv, float seed, float4 p0, float4 p1) {
    float a = p0.x, inc = p0.y * (M_PI_F / 180.0);
    float2 ab = kerrAB(uv, seedHand(seed), p0.z);
    Ray h = kerrRay(a, inc, ab, iscoR(a), p1.x);
    if (h.kind == 1) return float2(h.r, h.phi);
    if (h.kind == 0) return 0.0;
    // the observer sits at infinity, so add the parallax a camera 40M out would see
    float3 up = float3(-cos(inc), 0.0, sin(inc));
    return float2(-sky(normalize(h.dir + (ab.x * float3(0.0, 1.0, 0.0) + ab.y * up) * p0.z / 40.0), seedPan(seed)), 0.0);
}

// the central pull that makes a marched ray trace a Schwarzschild null geodesic
// exactly: with h = |d x v| the orbit obeys u'' + u = 3 m u^2, whatever the speed
static float3 bend(float3 d, float3 v, float m) {
    float r2 = dot(d, d);
    float3 h = cross(d, v);
    return -3.0 * m * dot(h, h) * d / (r2 * r2 * sqrt(r2));
}

// a pinhole camera at inclination inc and azimuth az looking at the origin
static float3 camRay(float2 uv, float inc, float az, float focal, float hand, thread float3 &o) {
    o = float3(sin(inc) * cos(az), sin(inc) * sin(az), cos(inc));
    float3 right = float3(-sin(az), cos(az), 0.0);
    return normalize(-focal * o + hand * uv.x * right - uv.y * cross(o, right));
}

static float roche(float3 x, float3 xs, float3 xb, float ms, float om2, thread float3 &grad) {
    float3 ds = x - xs, db = x - xb;
    float rs = length(ds), rb = length(db);
    grad = ms * ds / (rs * rs * rs) + db / (rb * rb * rb) - om2 * float3(x.xy, 0.0);
    return -ms / rs - 1.0 / rb - 0.5 * om2 * dot(x.xy, x.xy);
}

// ---------------------------------------------------------------- pipes (3D pass)

struct PipeVertex {
    float4 pos;
    float4 norm;
};

struct PipeInstance {
    float4 c0;  // model col 0 .xyz, material (1..12) in .w
    float4 c1;  // model col 1 .xyz, twoSided (0/1) in .w
    float4 c2;  // model col 2 .xyz
    float4 c3;  // model translation .xyz
};

struct PipeUniforms {
    float4x4 view;
    float4x4 proj;
    float4 params;  // shine, dissolve, blockSize, cycleSeed
};

struct PipeVOut {
    float4 pos [[position]];
    float3 normEye;
    float mat [[flat]];
    float twoSided [[flat]];
};

// Win98 SCRSAVE/PIPES/STATE.CXX + COMMON/MATERIAL.C: shininess (specExp * 128) and ks
constant float2 kPipeSpec[12] = {
    float2(76.8, 0.75), float2(76.8, 0.75), float2(32.0, 0.62), float2(76.8, 0.72),
    float2(28.0, 0.62), float2(32.0, 0.62), float2(51.2, 0.70), float2(64.0, 0.80),
    float2(12.8, 0.36), float2(12.8, 0.36), float2(10.0, 0.34), float2(11.3, 0.36)
};

// Dracula Pro dim and normal/bright pipe stops, paired with u.pal[0] bg and #F8F8F2 highlight
constant float3 kPipeDim[12] = {
    float3(0.467, 0.400, 0.800), // #7766CC purple
    float3(0.800, 0.400, 0.600), // #CC6699 pink
    float3(0.400, 0.800, 0.733), // #66CCBB cyan
    float3(0.431, 0.800, 0.400), // #6ECC66 green
    float3(0.722, 0.537, 0.290), // #B8894A orange/copper
    float3(0.800, 0.467, 0.400), // #CC7766 coral red
    float3(0.651, 0.651, 0.325), // #A6A653 brass/gold
    float3(0.475, 0.439, 0.663), // #7970A9 silver/comment
    float3(0.314, 0.298, 0.404), // #504C67 amethyst satin
    float3(0.306, 0.600, 0.286), // #4E9949 jade satin
    float3(0.286, 0.600, 0.549), // #49998C teal rubber
    float3(0.600, 0.302, 0.451)  // #994D73 blush pearl
};

constant float3 kPipeLit[12] = {
    float3(0.584, 0.502, 1.000), // #9580FF purple
    float3(1.000, 0.502, 0.749), // #FF80BF pink
    float3(0.502, 1.000, 0.918), // #80FFEA cyan
    float3(0.541, 1.000, 0.502), // #8AFF80 green
    float3(1.000, 0.792, 0.502), // #FFCA80 orange
    float3(1.000, 0.584, 0.502), // #FF9580 coral red
    float3(0.902, 0.902, 0.451), // #E6E673 gold
    float3(0.776, 0.776, 0.761), // #C6C6C2 silver/chrome
    float3(0.667, 0.600, 1.000), // #AA99FF bright purple
    float3(0.635, 1.000, 0.600), // #A2FF99 bright green
    float3(0.600, 1.000, 0.933), // #99FFEE bright cyan
    float3(1.000, 0.600, 0.800)  // #FF99CC bright pink
};

vertex PipeVOut pipesVert(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          device const PipeVertex *verts [[buffer(0)]],
                          device const PipeInstance *insts [[buffer(1)]],
                          constant PipeUniforms &pu [[buffer(2)]])
{
    PipeVertex v = verts[vid];
    PipeInstance m = insts[iid];
    float3 wp = m.c0.xyz * v.pos.x + m.c1.xyz * v.pos.y + m.c2.xyz * v.pos.z + m.c3.xyz;
    float3 wn = m.c0.xyz * v.norm.x + m.c1.xyz * v.norm.y + m.c2.xyz * v.norm.z;
    PipeVOut o;
    o.pos = pu.proj * (pu.view * float4(wp, 1.0));
    o.normEye = (pu.view * float4(wn, 0.0)).xyz;
    o.mat = m.c0.w;
    o.twoSided = m.c1.w;
    return o;
}

fragment float4 pipesFrag(PipeVOut in [[stage_in]],
                          bool front [[front_facing]],
                          constant PipeUniforms &pu [[buffer(0)]])
{
    if (pu.params.y > 0.0 && hash21(floor(in.pos.xy / pu.params.z) + pu.params.w) < pu.params.y)
        discard_fragment();

    float3 n = normalize(in.normEye);
    if (in.twoSided > 0.5 && !front) n = -n;

    // Win98 STATE::GLInit(): directional light0 at (90, 90, 150, 0), GL_LIGHT_MODEL_LOCAL_VIEWER = FALSE
    const float3 L = float3(0.4618083, 0.4618083, 0.7574656);
    const float3 H = float3(0.2456336, 0.2456336, 0.9377250);
    float diff = max(dot(n, L), 0.0);
    float rim = max(dot(n, float3(-0.35, -0.35, 0.87)), 0.0) * 0.07;

    int m = clamp(int(in.mat + 0.5) - 1, 0, 11);
    float2 sp = kPipeSpec[m];
    float spec = pow(max(dot(n, H), 0.0), sp.x) * sp.y * (pu.params.x / 1.2);
    float field = saturate(0.18 + 0.58 * diff + rim + spec * 0.44);
    return float4(field, in.mat, 0.0, 1.0);
}

// ---------------------------------------------------------------- shapes

// value noise with a quintic fade: continuous curvature, so a mirror shows no seams
static inline float vnoise5(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    return mix(mix(hash21(i), hash21(i + float2(1.0, 0.0)), u.x),
               mix(hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)), u.x), u.y);
}
static inline float fbm2s(float2 p) {
    return (vnoise5(p) * 0.6 + vnoise5(float2(p.x * 1.7 - p.y * 1.1, p.x * 1.1 + p.y * 1.7)) * 0.4);
}

// a slow liquid surface: broad noise warped twice by itself, each layer on its own slow orbit
static inline float mercH(float2 p, float time, float warp) {
    float w = 1.4 + 1.6 * warp;
    float2 q = float2(fbm2s(p + loop(0.7, time * 0.013)), fbm2s(p + float2(6.1, 2.4) - loop(0.9, time * 0.011)));
    float2 r = float2(fbm2s(p + w * q + float2(3.7, 8.2)), fbm2s(p + w * q + float2(9.4, 1.6) + loop(0.8, time * 0.009)));
    return fbm2s(p + w * r);
}

static float fieldOf(int shape, float2 uv, float seed, float warp, float time, float4 p0, float4 p1, float2 kt)
{
    float2 g = seedPan(seed);
    // g only pans the noise; these make seeds differ in scale, handedness and drift
    float sk = seed * 0.01;
    float4 k = float4(hash21(float2(sk, 1.7)), hash21(float2(sk, 9.2)),
                      hash21(float2(sk, 3.1)), hash21(float2(sk, 5.5)));
    float hand = seedHand(seed);
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
    case 15: {  // torus: a neon tube bent into a ring, tumbling, light chasing round it in a helix
                // p0: size, thickness, tumble, chase  p1.x: windings
        float3 ro = float3(0.0, 0.0, -2.6 / p0.x), rd = normalize(float3(uv, 1.5));
        float2x2 ra = rot(time * 0.21 * p0.z + k.z * 6.2831853), rb = rot(hand * time * 0.13 * p0.z + k.w * 6.2831853);
        ro.yz = ra * ro.yz; rd.yz = ra * rd.yz;
        ro.xy = rb * ro.xy; rd.xy = rb * rd.xy;
        float tube = p0.y, bound = 1.45 + tube;
        float b = dot(ro, rd), disc = b * b - dot(ro, ro) + bound * bound;
        if (disc <= 0.0) return 0.0;
        // the gas glows, the glass is clear: brightness is emission summed along the
        // ray, in steps that shrink inside the tube where the light is
        float t = -b - sqrt(disc), end = -b + sqrt(disc), acc = 0.0;
        for (int i = 0; i < 128 && t < end; ++i) {
            float3 p = ro + rd * t;
            float2 q = float2(length(p.xz) - 1.0, p.y);
            float d = length(q), dt = clamp(0.5 * (d - tube), 0.03, 0.2);
            float chase = sstep(1.5 * sin(round(p1.x) * atan2(p.z, p.x) + 2.0 * hand * atan2(q.y, q.x) - time * 2.5 * p0.w) + 0.3);
            acc += (exp(-3.0 * d * d / (tube * tube)) * (0.25 + 0.75 * chase)
                  + (0.02 + 0.08 * warp) * exp(-6.0 * max(d - tube, 0.0))) * dt;
            t += dt;
        }
        return 1.0 - exp(-5.0 * acc);
    }
    case 16: {  // kerr: a spinning hole and its thin disk, ray traced; spin 0 is Schwarzschild
                // p0: spin, inclination (deg), mass, disk temperature  p1.x: disk outer radius
                // kt: this pixel's kerrTrace, so a frame only has to light the disk
        if (kt.x <= 0.0) return -kt.x;
        float lam = -kerrAB(uv, hand, p0.z).x * sin(p0.y * (M_PI_F / 180.0));
        return diskLight(kt.x, lam, kt.y, p0.x, time / p0.z, g, warp, p0.w) * sstep((p1.x - kt.x) / (0.3 * p1.x));
    }
    case 17: {  // binary: two holes on a slow orbit with minidisks, lensing the sky and each other
        // ponytail: lensing superposes two Schwarzschild pulls; the exact two-body
        // metric needs numerical relativity, not a fragment shader
        // p0: mass ratio, separation, inclination (deg), orbit speed  p1.x: disk temperature
        float m2 = p0.x, sep = p0.y, ang = time * 0.05 * p0.w * pow(34.0 / sep, 1.5) + k.w * 6.2831853;
        float3 c1 = float3(float2(cos(ang), sin(ang)) * sep * m2 / (1.0 + m2), 0.0), c2 = -c1 / m2;
        // v runs backward along the light, so the photon's angular momentum is -(d x v)
        float3 o, v = camRay(uv, p0.z * (M_PI_F / 180.0), 0.0, 2.4, hand, o), x = o * 70.0 * sep / 34.0;
        for (int i = 0; i < 240; ++i) {
            float3 d1 = x - c1, d2 = x - c2;
            float r1 = length(d1), r2 = length(d2);
            if (r1 < 2.0 || r2 < 2.0 * m2) return 0.0;
            float dt = max(0.1 * min(r1, r2), 0.05) / length(v);
            v += (bend(d1, v, 1.0) + bend(d2, v, m2)) * dt;
            float3 xn = x + v * dt;
            if (x.z * xn.z < 0.0) {
                float3 p = mix(x, xn, x.z / (x.z - xn.z));
                for (int j = 0; j < 2; ++j) {
                    float m = j == 0 ? 1.0 : m2;
                    float3 d = p - (j == 0 ? c1 : c2);
                    float r = length(d) / m;
                    // minidisks are cut off by the companion's tides near a third of the separation
                    if (r > 6.0 && r * m < 0.32 * sep * pow(m, 1.0 / 3.0))
                        return diskLight(r, -cross(d, v).z / m, atan2(d.y, d.x), 0.0, time / m, g, warp, p1.x);
                }
            }
            x = xn;
            if (dot(x, x) > 5.0 * sep * sep && dot(x, v) > 0.0) return sky(normalize(v), g);
        }
        return 0.0;
    }
    case 18: {  // cygnus: a hole on a slow orbit round a supergiant that overflows its Roche lobe
                // into the hole's disk. Drawn in the frame co-rotating with the orbit, where
                // the star, stream and disk hold still and the camera circles
        // p0: star mass (in hole masses), inclination (deg), orbit speed, stream  p1.x: disk temperature
        const float sep = 40.0;
        float ms = p0.x;
        float om2 = (ms + 1.0) / (sep * sep * sep);
        float3 xs = float3(-sep / (ms + 1.0), 0.0, 0.0), xb = float3(sep * ms / (ms + 1.0), 0.0, 0.0);
        // L1: where gravity and the centrifugal pull cancel on the axis, the gradient falls monotonically
        float lo = xs.x + 1.0, hi = xb.x - 1.0;
        for (int i = 0; i < 24; ++i) {
            float m = 0.5 * (lo + hi);
            if (ms / ((m - xs.x) * (m - xs.x)) - 1.0 / ((xb.x - m) * (xb.x - m)) - om2 * m > 0.0) lo = m; else hi = m;
        }
        float3 grad;
        float l1 = lo, reach = l1 - xs.x, surf = roche(float3(l1, 0.0, 0.0), xs, xb, ms, om2, grad);
        // the disk fills three quarters of the hole's Roche lobe (Eggleton's radius)
        float q3 = pow(1.0 / ms, 1.0 / 3.0);
        float rout = 0.75 * sep * 0.49 * q3 * q3 / (0.6 * q3 * q3 + log(1.0 + q3));
        float spin = sqrt(om2) * 10.0 * time * p0.z;
        float3 o, v = camRay(uv, p0.y * (M_PI_F / 180.0), k.w * 6.2831853 - spin, 4.5, hand, o), x = o * 120.0;
        float2x2 back = rot(spin);   // escaping rays look up at a sky that does not co-rotate
        float3 xp = x;
        for (int i = 0; i < 240; ++i) {
            float3 d = x - xb;
            float r = length(d);
            if (r < 2.0) return 0.0;
            float ph = roche(x, xs, xb, ms, om2, grad), out = distance(x, xs) - reach;
            if (out < 0.0 && x.x < l1 && ph < surf) {
                float3 lo3 = xp, hi3 = x;
                for (int j = 0; j < 6; ++j) {
                    float3 m = 0.5 * (lo3 + hi3);
                    if (roche(m, xs, xb, ms, om2, grad) < surf) hi3 = m; else lo3 = m;
                }
                // surface gravity at the pole, the brightest point, found up the spin axis
                float zlo = 1.0, zhi = reach;
                for (int j = 0; j < 16; ++j) {
                    float zm = 0.5 * (zlo + zhi);
                    if (roche(xs + float3(0.0, 0.0, zm), xs, xb, ms, om2, grad) < surf) zlo = zm; else zhi = zm;
                }
                roche(xs + float3(0.0, 0.0, zlo), xs, xb, ms, om2, grad);
                float gpole = length(grad);
                roche(hi3, xs, xb, ms, om2, grad);
                float gn = length(grad);
                float limb = 1.0 - 0.6 * (1.0 - abs(dot(grad / gn, normalize(v))));
                float gran = fbm3(g + float2(hi3.x + hi3.z * 0.7, hi3.y - hi3.z * 0.6) * 0.45 + time * 0.05);
                // von Zeipel: flux follows surface gravity, so the L1 tip goes dark
                return saturate(0.85 * limb * gn / gpole * (0.75 + 0.5 * gran));
            }
            // the potential over its gradient is a first-order distance to the star
            float ds = out > 0.0 ? out + 0.5 : (x.x < l1 ? 0.8 * (ph - surf) / length(grad) : 0.5);
            float dt = max(min(0.1 * r, ds), 0.04) / length(v);
            v += bend(d, v, 1.0) * dt;
            xp = x;
            x += v * dt;
            if (xp.z * x.z < 0.0) {
                float2 q = mix(xp, x, xp.z / (xp.z - x.z)).xy - xb.xy;
                float rho = length(q), psi = atan2(q.y, q.x);
                float2 spot = 0.9 * rout * float2(cos(M_PI_F + 1.4), sin(M_PI_F + 1.4));
                if (rho > 6.0 && rho < rout)
                    return saturate(diskLight(rho, q.y * v.x - q.x * v.y, psi, 0.0, time, g, warp, p1.x)
                                    + 0.6 * exp(-0.3 * dot(q - spot, q - spot)));
                // the stream leaves L1 and Coriolis swings it ahead of the hole into the rim
                float s = fract((psi - M_PI_F) / 6.2831853) * 6.2831853 / 1.4;
                float across = (rho - mix(xb.x - l1, 0.9 * rout, sqrt(s))) / (mix(0.5, 1.6, s) * (0.6 + 0.8 * p0.w));
                if (s < 1.0 && abs(across) < 1.0)
                    return saturate((0.3 + 0.35 * s) * (1.0 - across * across)
                                    * (0.6 + 0.8 * fbm3(g + float2(s * 9.0 - time * 1.2, across))));
            }
            if (dot(x, x) > 125.0 * 125.0 && dot(x, v) > 0.0) {
                float3 e = normalize(v);
                return sky(float3(back * e.xy, e.z), g);
            }
        }
        return 0.0;
    }
    case 19:
        return 0.0; // rendered in the 3D pipes pre-pass into `trace`
    case 20: {  // drape: satin in overlapping folds, a sheen across each, a lit hem, a shadow under it
        float2 p = rot((k.z - 0.5) * 1.2) * uv + drift * loop(2.0, time * 0.03);
        float v = 0.06;
        for (int i = 0; i < 5; ++i) {
            float fi = float(i);
            float x = p.x * mix(1.2, 2.2, hash21(g + fi * 7.3)) + fi * 1.9 + g.x;
            float hem = -0.95 + fi * 0.42 + 0.18 * sin(x + hand * time * (0.08 + 0.03 * fi))
                      + (fbm3(float2(x * 0.7, fi + time * 0.02)) - 0.5) * (0.3 + 0.6 * warp);
            float d = p.y - hem;   // y grows downward, the cloth hangs below its hem
            if (d < 0.0) { v *= 1.0 - 0.5 * exp(d * 30.0); continue; }
            float sheen = 0.5 + 0.5 * sin(x * 2.3 + d * 3.0 - time * 0.1 + fi);
            v = 0.2 + 0.55 * exp(-d * 1.5) * (0.4 + 0.6 * sheen * sheen) + 0.35 * exp(-d * 60.0);
        }
        return saturate(v);
    }
    case 21: {  // mercury: liquid metal, broad slow swells mirroring a soft studio
        float2 p = g + rot(0.4) * uv * mix(0.3, 0.42, k.x);
        const float e = 0.003;
        float h = mercH(p, time, warp);
        float2 grad = float2(mercH(p + float2(e, 0.0), time, warp) - h, mercH(p + float2(0.0, e), time, warp) - h) / e;
        float3 n = normalize(float3(-grad * 0.5, 1.0));
        float3 r = float3(2.0 * n.z * n.xy, 2.0 * n.z * n.z - 1.0);
        float2x2 turn = rot(k.w * 6.2831853);
        float3 key = normalize(float3(turn * float2(-0.5, -0.6), 0.6));
        float3 fill = normalize(float3(turn * float2(0.6, 0.3), 0.5));
        float sky = sstep((dot(r, key) + 0.3) * 0.8);
        float ring = exp(-pow(length(r.xy) - 0.65, 2.0) * 400.0);
        float lit = 0.04 + 0.9 * sky * sqrt(sky) + 0.25 * ring * sky
                  + 1.1 * pow(saturate(dot(r, key)), 50.0) + 0.4 * pow(saturate(dot(r, fill)), 40.0);
        // troughs see less of the room
        return saturate(lit * (0.55 + 0.45 * saturate(h * 1.8 - 0.35)));
    }
    case 22: {  // tyndall: shafts of light fanning in from a corner through dusty air
        float2 o = float2(k.w < 0.5 ? -1.9 : 1.9, -1.25 + 0.3 * k.y);
        float2 d = uv - o;
        float r = length(d);
        float2 q = rot(hand * time * 0.01) * (d / r);
        float shaft = fbm3(q * mix(6.0, 10.0, k.x) + g + float2(0.0, time * 0.04));
        shaft = pow(saturate((shaft - 0.25) * (1.6 + warp)), 1.5);
        float dust = fbm3(uv * 3.0 + g + loop(2.0, time * 0.05));
        return saturate(exp(-max(r - 0.8, 0.0) * 0.45) * (0.15 + 1.1 * shaft * (0.7 + 0.6 * dust)) + 0.03);
    }
    case 23: {  // corona: a total eclipse, the corona breathing round the moon's rim
        float2 p = uv - (k.xy - 0.5) * float2(1.2, 0.5);
        float R = 0.36 + 0.06 * k.w + 0.008 * sin(time * 0.4);
        float r = length(p);
        if (r < R) return 0.015;
        float2 dir = p / r;
        float x = r - R;
        float st = fbm3(rot(hand * time * 0.004) * dir * 2.5 + g + float2(0.0, x * 1.2 - time * 0.03));
        float corona = exp(-x * mix(9.0, 4.0, st) / (0.6 + warp));
        // the last bead of sun showing at the rim: the diamond ring, on some seeds
        float2 bd = p - R * float2(cos(k.z * 6.2831853), sin(k.z * 6.2831853));
        float bead = step(0.5, k.y) * exp(-dot(bd, bd) * 900.0);
        return saturate(0.03 + 0.8 * corona * (0.5 + 0.8 * st) + 0.5 * exp(-x * 90.0) + bead);
    }
    case 24: {  // streamer: one ribbon of light turning over itself across a dark frame
        float2 p = rot((k.z - 0.5) * 0.9) * uv;
        float x = p.x * mix(0.9, 1.4, k.x) + g.x;
        float c = 0.32 * sin(x * 1.1 + hand * time * 0.07) + 0.12 * sin(x * 2.3 + g.y - time * 0.05);
        float tw = x * mix(1.2, 2.2, k.y) + hand * time * 0.1 + warp * 1.5 * sin(x * 0.7);
        float w = 0.16 * cos(tw);   // the half-width passes through zero where the ribbon flips
        float d = abs(p.y - c), aw = abs(w);
        if (d > aw) return saturate(0.03 + 0.25 * exp(-(d - aw) * 10.0) * aw / 0.16);
        float across = d / max(aw, 1e-4);
        float face = w > 0.0 ? 0.55 + 0.45 * aw / 0.16 : 0.3 + 0.2 * aw / 0.16;
        return saturate(face * (0.6 + 0.4 * (1.0 - across * across)) + 0.4 * exp(-(aw - d) * 60.0));
    }
    case 25: {  // borealis: aurora curtains rising off the horizon into a starry sky
        float2 sc = floor((uv + g) * 90.0);
        float star = step(0.996, hash21(sc)) * hash21(sc + 3.1) * (0.35 + 0.15 * sin(time * 2.0 + hash21(sc + 7.7) * 40.0));
        float v = 0.0;
        for (int i = 0; i < 2; ++i) {
            float fi = float(i);
            float x = uv.x * (1.0 + 0.5 * fi) + g.x + fi * 3.7;
            float foot = 0.45 + 0.25 * fi - 0.3 * fbm3(float2(x * 0.5, time * 0.03 + fi));
            float pleat = fbm3(float2(x * 7.0 + (fbm3(float2(x, time * 0.05)) - 0.5) * (1.0 + 3.0 * warp),
                                      time * 0.08 + fi * 5.0));
            float hgt = foot - uv.y;
            float body = hgt > 0.0 ? exp(-hgt * mix(1.2, 2.5, k.x)) : exp(hgt * 25.0);
            v = max(v, body * (0.25 + 0.9 * pleat * pleat) * (1.0 - 0.35 * fi));
        }
        return saturate(v + star * (1.0 - v) + 0.02);
    }
    case 26: {  // pulsar: a burst of rays wheeling slowly round a white-hot core
        float2 p = uv - (k.xy - 0.5) * float2(1.0, 0.6);
        float r = length(p);
        float2 q = rot(hand * time * 0.03) * (p / max(r, 1e-4));
        float rays = pow(saturate(fbm3(q * mix(5.0, 9.0, k.w) + g) * 1.4 - 0.25), 3.0) * (0.6 + 0.4 * vnoise(q * 40.0 + g));
        return saturate(exp(-r * r * 60.0) + 0.35 * exp(-r * 3.0) + rays * (1.2 + warp) / (1.0 + r * 3.0));
    }
    case 27: {  // limelight: one streaked cone of light thrown down from above, dust in the beam
        float2 src = float2((k.x - 0.5) * 1.4, -1.4);
        float2 d = uv - src;
        float ang = atan2(d.x, d.y) - (k.y - 0.5) * 0.3;   // 0 is straight down
        float spread = mix(0.22, 0.34, k.w);
        float cone = sstep((spread - abs(ang)) / 0.08);
        float streak = fbm3(float2(ang * mix(18.0, 30.0, k.z), time * 0.05) + g);
        if (uv.y > 0.8) {   // the pool where the cone meets the floor
            float2 c = float2(src.x + 2.2 * tan((k.y - 0.5) * 0.3), 0.86);
            float2 e = (uv - c) / float2(2.2 * tan(spread), 0.08);
            return saturate(0.04 + 0.7 * exp(-dot(e, e) * 1.5));
        }
        float2 mp = uv * 30.0 + float2(0.0, time * 0.3) + g, mf = fract(mp) - 0.5;
        float mote = step(0.97, hash21(floor(mp))) * exp(-dot(mf, mf) * 40.0);
        float beam = cone * ((0.3 + 0.7 * streak * streak) * exp(-length(d) * 0.35) * (0.8 + 0.4 * warp) + 0.5 * mote);
        return saturate(beam + 0.03);
    }
    case 28: {  // shutter: a beam of colour dragged across the frame, smeared like a long exposure
        float2 p = rot((k.z - 0.5) * 1.4) * uv;
        float c = 0.3 * sin(p.x * mix(0.8, 1.4, k.x) + g.x + hand * time * 0.05) + 0.1 * sin(p.x * 2.7 + g.y);
        float w = 0.1 + 0.08 * sin(p.x * 0.9 + g.y + time * 0.04);
        float d = (p.y - c) / w;
        float strands = vnoise(float2(p.x * 0.6 - time * 0.05, d * 6.0 + g.y));
        float head = sstep((p.x * hand + 1.6) / 3.2);   // brighter where the light ended up
        float beam = exp(-d * d) * (0.35 + 0.65 * strands) * (0.25 + 0.75 * head);
        return saturate(beam * (1.0 + 0.5 * warp) + 0.12 * exp(-abs(d) * 0.8) + 0.02);
    }
    case 29: {  // limb: the edge of a giant planet lit from behind, a thin crest of atmosphere
        float R = mix(1.6, 2.6, k.x);
        float2 up = rot((k.z - 0.5) * 2.0) * float2(0.0, -1.0);
        float2 p = uv + up * (R + 0.35);
        float r = length(p);
        float2 lxy = rot((k.w - 0.5) * 1.2 + 0.1 * sin(time * 0.02)) * up;
        float3 l = normalize(float3(lxy, -0.45));
        float facing = saturate(dot(p / r, lxy));
        float x = r - R;
        if (x < 0.0) {
            float3 n = float3(p / R, sqrt(max(1.0 - r * r / (R * R), 0.0)));
            float bands = fbm3(float2(dot(p, up) * 9.0, dot(p, float2(-up.y, up.x)) * 0.8 + time * 0.01) + g);
            return saturate(max(dot(n, l), 0.0) * (0.55 + 0.5 * bands) * (1.5 + warp) + 0.45 * facing * exp(x * 40.0) + 0.02);
        }
        float2 sc = floor((uv + g) * 80.0);
        float star = step(0.995, hash21(sc)) * 0.3 * hash21(sc + 1.3);
        return saturate(exp(-x * 18.0) * (0.1 + 0.6 * facing) + 0.5 * facing * exp(-x * 90.0) + star + 0.01);
    }
    case 30: {  // luxfer: glass blocks lit from behind by slow soft glows
        float2 p = g + uv * mix(4.0, 7.0, k.x);
        float2 cell = floor(p), f = fract(p) - 0.5;
        // each block is a pillow lens, so the glow behind it is seen bent and magnified
        float2 lens = f * (0.6 + 0.6 * warp) * (1.0 - dot(f, f));
        float glow = sstep((fbm3((cell + 0.5 + lens) * 0.25 + drift * loop(2.0, time * 0.04)) - 0.35) * 2.5);
        float edge = max(abs(f.x), abs(f.y));
        float grout = sstep((edge - 0.44) * 25.0);
        float bevel = sstep((edge - 0.34) * 10.0) * (1.0 - grout) * saturate(0.5 - f.x - f.y);
        float ribs = 0.9 + 0.1 * cos(f.x * 40.0);
        return saturate(mix(glow * ribs * 0.85 + 0.06, 0.03, grout) + 0.3 * bevel * glow);
    }
    }
}

// ---------------------------------------------------------------- dither

static inline float3 ramp(constant Uniforms &u, float t, float colors) {
    float f = saturate(t) * (colors - 1.0);
    int i0 = max(min(int(f), int(colors) - 2), 0);
    return mix(u.pal[i0].rgb, u.pal[i0 + 1].rgb, f - float(i0));
}

static inline float3 pipeRamp(constant Uniforms &u, int pipeMat, float t, float colors) {
    if (pipeMat <= 0) return ramp(u, t, colors);
    int n = clamp(int(colors + 0.5), 2, 5);
    float3 mid = u.pal[min(2, n - 1)].rgb;
    if (max(mid.x, max(mid.y, mid.z)) - min(mid.x, min(mid.y, mid.z)) < 0.04)
        return ramp(u, t, colors);

    int m = clamp(pipeMat - 1, 0, 11);
    float3 bg = u.pal[0].rgb;
    float3 p[5] = {
        bg,
        mix(bg, kPipeDim[m], 0.45),
        kPipeDim[m],
        kPipeLit[m],
        float3(0.973, 0.973, 0.949)
    };
    float f = saturate(t) * float(n - 1);
    int i0 = clamp(int(f), 0, n - 2);
    int s0 = int(rint(float(i0) * 4.0 / float(n - 1)));
    int s1 = (n == 2) ? 3 : int(rint(float(i0 + 1) * 4.0 / float(n - 1)));
    return mix(p[s0], p[s1], f - float(i0));
}

// Every dither quantises the field onto the palette, so anything that wants to
// darken or roughen the picture has to move the *field* before that happens.
// Doing it to the colour afterwards invents colours the palette does not have.
static float3 shade(int dither, float field, float2 uv, float pixelSize, float colors,
                    int pipeMat, constant Uniforms &u, texture2d<float> atlas)
{
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float levels = max(colors, 2.0) - 1.0;
    float2 cell = floor(uv / pixelSize);
    float2 cuv = fract(uv / pixelSize);

    if (dither == 8) {          // ascii: glyph density is the shade, palette stays two-tone
        float lvl = min(floor(levels * field + 0.5), levels);
        float3 fg = pipeRamp(u, pipeMat, lvl / levels, colors);
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
        return pipeRamp(u, pipeMat, qz, colors);
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
    return pipeRamp(u, pipeMat, qz, colors);
}

// ---------------------------------------------------------------- entry

struct VOut { float4 pos [[position]]; };

vertex VOut vmain(uint id [[vertex_id]]) {
    VOut o;
    o.pos = float4(float((id << 1) & 2) * 2.0 - 1.0, float(id & 2) * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

static inline float2 screenUV(float2 pos, constant Uniforms &u) {
    return (pos - u.view.xy * 0.5) * (1.95 / max(u.view.z, 0.01)) / u.view.y;
}

// fills the renderer's per-pixel Kerr cache that fmain reads back
fragment float4 ktrace(float4 pos [[position]], constant Uniforms &u [[buffer(0)]]) {
    return float4(kerrTrace(screenUV(pos.xy, u), u.misc.x, u.shp[0], u.shp[1]), 0.0, 0.0);
}

fragment float4 fmain(float4 pos [[position]],
                      constant Uniforms &u [[buffer(0)]],
                      texture2d<float> photo [[texture(0)]],
                      texture2d<float> atlas [[texture(1)]],
                      texture2d<float> trace [[texture(2)]])
{
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 res = u.view.xy;
    float2 uv = pos.xy;

    int pipeMat = 0;
    float field;
    if (u.view.w > 0.5) {
        field = dot(photo.sample(smp, uv / res).rgb, float3(0.299, 0.587, 0.114));
    } else {
        int shape = int(u.look.x);
        if (shape == 19) {
            float2 pt = trace.read(uint2(uv)).xy;
            field = pt.x;
            pipeMat = int(pt.y + 0.5);
        } else {
            float2 kt = shape == 16 ? trace.read(uint2(uv)).xy : 0.0;
            field = fieldOf(shape, screenUV(uv, u), u.misc.x, u.tune.x, u.misc.z, u.shp[0], u.shp[1], kt);
        }
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

    float3 c = shade(int(u.look.y), field, uv, u.look.z, u.look.w, pipeMat, u, atlas);
    return float4(c, 1.0);
}

// selftest only: checks kerrRay against Bardeen's analytic shadow edge
kernel void kerrProbe(device const float4 *q [[buffer(0)]], device float2 *o [[buffer(1)]],
                      uint i [[thread_position_in_grid]]) {
    float4 p = q[2 * i], d = q[2 * i + 1];
    Ray h = kerrRay(p.x, p.y, p.zw, d.x, d.y);
    o[i] = float2(h.kind, h.kind == 1 ? diskShift(h.r, h.lam, p.x) : 0.0);
}
