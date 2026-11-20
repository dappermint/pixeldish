// A slice through two colliding winds. Radiative cooling is approximated by an
// isothermal gas: P = c_s² rho. The state is (rho, rho vx, rho vy, stellar ejecta density).
constant float windSound = 0.30;

struct WindParams {
    float4 controls;   // ambient wind speed, viscosity, gravitating mass, outflow strength
    float4 source;     // seed, simulation time, reset, timestep
};

static float2 windStar(float2 size, float seed) {
    return size * float2(0.55, 0.40 + 0.075 * (fract(seed * 0.7137) - 0.5));
}

static float2 windAxis(float seed, float t) {
    float a = 0.28 + 0.38 * fract(seed * 0.3711) + 0.12 * sin(0.021 * t + seed);
    return float2(sin(a), -cos(a));
}

// Coordinates parallel and perpendicular to the common jet/disk axis.
static float2 windJetCoords(float2 offset, float2 axis) {
    return float2(dot(offset, axis), dot(offset, float2(-axis.y, axis.x)));
}

static float windNozzle(float2 jet) {
    float2 d = float2((abs(jet.x) - 4.6) / 1.75, jet.y / 1.2);
    return exp(-0.5 * dot(d, d));
}

static float windGM(float gravity) { return 5.6 * gravity; }

static float4 windConserved(float4 q) { return float4(q.x, q.x * q.yzw); }
static float4 windPrimitive(float4 s) { return float4(s.x, s.yzw / max(s.x, 0.0001)); }

// Both the visible photosphere and the wind boundary use these grid coordinates.
static float3 windGiant(float2 size) { return float3(0.025 * size.x, 0.74 * size.y, 0.61 * size.y); }

static float windPulse(float t, float seed) {
    float wave = 0.5 + 0.5 * cos(0.076 * t + seed);
    return wave * wave * wave;
}

static float2 windVent(float2 size, float seed, float t) {
    float2 heading = normalize(windStar(size, seed) - windGiant(size).xy);
    return rot(0.085 * sin(0.052 * t + seed) + 0.052 * sin(0.021 * t)) * heading;
}

// The second tracer remembers the parcel's launch position across the vent. It
// stretches with the flow, so a bundle of fine bright threads survives transport.
struct WindLaunch { float4 gas; float2 tracer; };

static WindLaunch windLaunch(float2 pos, float2 size, float t, float seed, float speed) {
    float3 giant = windGiant(size);
    float2 offset = pos - giant.xy;
    float d = max(length(offset), 0.01);
    float2 n = offset / d;
    // Fill a cold frame with earlier wind. Once running, only the surface supplies new gas.
    t -= max(0.0, d - giant.z) / speed;
    float2 vent = windVent(size, seed, t);
    float arc = giant.z * dot(n, float2(-vent.y, vent.x));
    float jet = exp(-0.5 * arc * arc / 47.0) * saturate(dot(n, vent));
    float pulse = windPulse(t, seed);
    float2 patch = float2(arc * 0.16 + seed, t * 0.057);
    float braid = 0.5 + 0.5 * cos(1.9 * arc + 5.5 * vnoise(patch) + 0.065 * t);
    float mass = 0.28 + 0.14 * vnoise(patch * 0.6) + jet * (1.1 + 5.2 * pulse) * (0.55 + 0.85 * braid);
    float2 v = speed * (1.0 + jet * (0.27 + 0.70 * pulse)) * n;
    v += float2(-n.y, n.x) * jet * 0.09 * sin(0.06 * t);
    float2 tracer = float2(jet * (0.36 + 0.52 * pulse + 0.12 * braid), arc + 2.8 * vnoise(patch) + sin(0.07 * t));
    return {windConserved(float4(mass * min(1.0, giant.z / d), v, 0.0)), tracer};
}

// HLL flux with piecewise-linear reconstruction. Both cells sharing a face
// compute the same mass, momentum and tracer flux through it.
static float4 windSlope(float4 a, float4 b) {
    return 0.5 * (sign(a) + sign(b)) * min(abs(a), abs(b));
}
static float4 windFlux(float4 l, float4 r, float2 axis) {
    float vl = dot(l.yz, axis), vr = dot(r.yz, axis);
    float sl = min(0.0, min(vl, vr) - windSound), sr = max(0.0, max(vl, vr) + windSound);
    float4 ul = windConserved(l), ur = windConserved(r);
    float4 fl = vl * ul, fr = vr * ur;
    fl.yz += windSound * windSound * l.x * axis;
    fr.yz += windSound * windSound * r.x * axis;
    return (sr * fl - sl * fr + sl * sr * (ur - ul)) / (sr - sl);
}
static float4 windRead(texture2d<float, access::read> tex, int2 p, int2 last) {
    return windPrimitive(tex.read(uint2(clamp(p, int2(0), last))));
}
static float4 windTransport(texture2d<float, access::read> tex, int2 p, int2 d, int2 last, float4 q, float nu) {
    float4 a = windRead(tex, p - d, last), b = windRead(tex, p + d, last);
    float4 slope = 0.5 * windSlope(q - a, b - q);
    float4 left = a + 0.5 * windSlope(a - windRead(tex, p - 2 * d, last), q - a);
    float4 right = b - 0.5 * windSlope(b - q, windRead(tex, p + 2 * d, last) - b);
    float4 flux = windFlux(left, q - slope, float2(d)) - windFlux(q + slope, right, float2(d));
    flux.yz += nu * (min(b.x, q.x) * (b.yz - q.yz) - min(a.x, q.x) * (q.yz - a.yz));
    return flux;
}

kernel void wakeWind(texture2d<float, access::read> before [[texture(0)]],
                     texture2d<float, access::write> after [[texture(1)]],
                     constant WindParams &u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    int2 p = int2(gid), size = int2(after.get_width(), after.get_height());
    float seed = u.source.x, t = u.source.y, dt = u.source.w, speed = 0.85 * u.controls.x;
    float3 giant = windGiant(float2(size));
    float height = distance(float2(p), giant.xy) - giant.z;
    if (height < -3.0) {
        after.write(float4(1, 0, 0, 0), gid);
        return;
    }
    if (u.source.z > 0.5 || height <= 0.0) {
        after.write(windLaunch(float2(p), float2(size), t, seed, speed).gas, gid);
        return;
    }
    float4 s = before.read(gid), q = windPrimitive(s);
    float nu = 0.026 * u.controls.y;
    s += dt * (windTransport(before, p, int2(1, 0), size - 1, q, nu)
                 + windTransport(before, p, int2(0, 1), size - 1, q, nu));

    float2 offset = float2(p) - windStar(float2(size), seed);
    float r2 = dot(offset, offset);
    // Newtonian gravity softened over the unresolved core, in grid units.
    float invR = rsqrt(r2 + 3.5 * 3.5);
    s.yz -= dt * s.x * windGM(u.controls.z) * offset * (invR * invR * invR);
    // Material entering the core accretes, carrying its momentum and tracer with it.
    s *= 1.0 - (0.58 * dt) * exp(-0.25 * r2);

    // A bipolar mass and momentum source represents the protostar's inner jet engine.
    // The crosswind subsequently steers both lobes through the same flux update as the gas.
    float2 axis = windAxis(seed, t);
    float2 jet = windJetCoords(offset, axis);
    float burst = 0.5 + 0.5 * sin(0.14 * t + 0.7 * sin(0.043 * t + seed));
    float rate = 0.64 + 1.12 * burst * burst;
    float added = dt * u.controls.w * rate * windNozzle(jet);
    s += added * float4(1.0, sign(jet.x) * (2.40 + 0.68 * burst) * axis, 1.0);
    // An evacuated jet cavity can round to zero in the half-float grid. Add
    // stationary ambient gas at the same density floor used to recover velocity.
    s.x = max(s.x, 0.0001);
    s.w = clamp(s.w, 0.0, s.x);
    after.write(s, gid);
}

// Optically bright knots travel in the computed velocity field. A finer grid
// lets a compressed sheet remain visible when it is thinner than a hydro cell.
kernel void wakeFilaments(texture2d<float> before [[texture(0)]], texture2d<float, access::write> after [[texture(1)]],
                          texture2d<float> gas [[texture(2)]], constant WindParams &u [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 size(gas.get_width(), gas.get_height()), uv = (float2(gid) + 0.5) / (size * 2.0);
    float2 p = uv * size - 0.5;
    float t = u.source.y, seed = u.source.x;
    float2 tracer;
    float3 giant = windGiant(size);
    float height = distance(p, giant.xy) - giant.z;
    if (height < -3.0) {
        tracer = 0.0;
    } else if (u.source.z > 0.5 || height <= 0.0) {
        tracer = windLaunch(p, size, t, seed, 0.85 * u.controls.x).tracer;
    } else {
        float2 dt = 4.0 * u.source.w / size;
        float4 s = gas.sample(smp, uv);
        float4 mid = gas.sample(smp, uv - 0.5 * dt * s.yz / s.x);
        tracer = before.sample(smp, uv - dt * mid.yz / mid.x).xy;
        float2 jet = windJetCoords(p - windStar(size, seed), windAxis(seed, t));
        float pulse = 0.5 + 0.5 * sin(0.4 * t + 2.4 * jet.y + sign(jet.x));
        tracer = mix(tracer, float2(pulse, jet.y), saturate(0.55 * u.controls.w * windNozzle(jet)));
    }
    after.write(float4(tracer, 0, 0), gid);
}

// Rotating spherical coordinates foreshorten the convection cells at the limb.
static float giantPhotosphere(float2 q, float t, float seed) {
    float z = sqrt(saturate(1.0 - dot(q, q)));
    float2 longitude = rot(0.0035 * t + seed) * float2(q.x, z);
    float2 p = 5.7 * float2(longitude.x + 0.32 * longitude.y, q.y - 0.38 * longitude.y) + seedPan(seed);
    float2 drift = loop(0.8, t * 0.018);
    float2 currents = float2(fbm3(p * 0.75 + drift), fbm3(p * 0.75 - drift + 7.3));
    float2 cell = p + 2.0 * currents;
    float broad = fbm5(cell * 1.4 + drift * 0.25);
    float lanes = abs(fbm3(cell * 3.6 + 2.4 * currents) - 0.48);
    float filigree = fbm3(cell * 13.0 + 3.0 * currents);
    float heat = 0.34 + 0.61 * smoothstep(0.23, 0.65, broad)
               - 0.28 * exp(-lanes * 17.0) + 0.18 * (filigree - 0.36);
    return heat * (0.64 + 0.36 * sqrt(z));
}

// Three strands of one prominence share footpoints on the active limb. Distances
// are in the same world units as the material leaving the surface.
static float giantCorona(float2 n, float height, float radius, float2 vent, float t, float seed) {
    float pulse = windPulse(t, seed);
    float2 arch = rot(-0.38) * vent;
    float along = radius * dot(n, float2(-arch.y, arch.x));
    float spicules = vnoise(n * 110.0 + 0.7 * loop(1.0, t * 0.06) + seedPan(seed));
    float corona = (0.15 + 0.40 * spicules) * exp(-height / (1.4 + 3.2 * spicules));
    if (dot(n, arch) < 0.80 || abs(along) > 31.0 || height > 38.0) return corona;
    float2 twist = float2(along * 0.13 + seed, height * 0.18 - 0.065 * t);
    float ripple = fbm3(twist);
    along += 3.8 * sin(height * 0.18 + 5.0 * ripple);
    for (int i = 0; i < 3; ++i) {
        float strand = float(i);
        float x = (along - 1.8 * strand - height * 0.36) / (16.0 + 2.4 * strand);
        float crest = (15.0 + 4.0 * strand + 7.0 * pulse) * (1.0 - x * x) + 6.0 * (ripple - 0.5) + strand * sin(twist.x);
        float dist = abs(height - crest) / sqrt(1.0 + 5.0 * x * x);
        float glow = (0.16 + 0.70 * ripple) * exp(-dist / (0.35 + 1.10 * ripple)) + 0.11 * exp(-dist / 3.2);
        corona += glow * smoothstep(-3.0, 1.0, crest);
    }
    return corona;
}

// Four bilinear taps reconstruct a quadratic B-spline across cell boundaries.
// Pixel coordinates include the half-texel offset to the cell centre.
static float4 windSample(texture2d<float> tex, float2 pixel) {
    constexpr sampler smp(coord::pixel, filter::linear, address::clamp_to_edge);
    float2 f = fract(pixel), center = floor(pixel) + 0.5;
    float2 lo = center - (1.0 - f) * (1.0 - f), hi = center + f * f;
    return 0.25 * (tex.sample(smp, lo) + tex.sample(smp, float2(hi.x, lo.y))
                 + tex.sample(smp, float2(lo.x, hi.y)) + tex.sample(smp, hi));
}

static float wakeField(texture2d<float> plasma, texture2d<float> filaments, float2 pos, constant Uniforms &u) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 res = u.view.xy;
    if (res.y > res.x) { pos = float2(res.y - pos.y, pos.x); res = res.yx; }
    float2 size(plasma.get_width(), plasma.get_height());
    // Keep both stars in frame across the zoom range. Portrait sees the giant rise from below.
    float width = size.x * 0.80 / (0.68 + 0.32 * u.view.z);
    float2 span = width * res / res.x;
    float2 p = float2(0.0, size.y * 0.5) + (pos / res - float2(0.0, 0.5)) * span;
    float t = u.shp[1].w, seed = u.misc.x;
    float3 giant = windGiant(size);
    float2 delta = p - giant.xy;
    float d = max(length(delta), 0.01), height = d - giant.z;
    float2 n = delta / d;
    float2 vent = windVent(size, seed, t);
    float active = saturate(dot(n, vent));
    if (height < -0.35) {
        float limb = exp(height / 1.1) * (0.30 + 0.22 * active);
        return saturate(giantPhotosphere(delta / giant.z, t, seed) + limb);
    }

    float2 pixel = p + 0.5;
    float4 s = windSample(plasma, pixel);
    float2 tracer = windSample(filaments, 2.0 * pixel).xy;
    float rho = max(s.x, 0.001), threads = sqrt(saturate(tracer.x));
    float gx = windSample(plasma, pixel + float2(1, 0)).x - windSample(plasma, pixel - float2(1, 0)).x;
    float gy = windSample(plasma, pixel + float2(0, 1)).x - windSample(plasma, pixel - float2(0, 1)).x;
    float shock = length(float2(gx, gy)) / sqrt(rho);
    float light = (0.11 + 0.40 * threads) * rho * rho + 1.65 * shock + 0.3 * s.w;
    float gas = (0.72 + 0.28 * threads) * (1.0 - exp(-0.64 * log2(1.0 + light)));
    float strands = 0.5 + 0.5 * sin(1.56 * tracer.y + 1.9 * sin(0.48 * tracer.y));
    float emission = smoothstep(0.025, 0.67, tracer.x) * (0.34 + 0.70 * strands * strands);
    // Radiation from the giant lights the stream most strongly near its source.
    float irradiation = min(1.0, 1.45 * giant.z / d);
    gas += emission * smoothstep(0.12, 0.55, rho) * irradiation * irradiation;
    gas *= smoothstep(-0.5, 7.5, min(p.y, size.y - p.y));

    float2 star = windStar(size, seed);
    float2 offset = p - star, jet = windJetCoords(offset, windAxis(seed, t));
    float r2 = dot(offset, offset), disk = length(float2(jet.y, 3.5 * jet.x));
    float coreDensity = plasma.sample(smp, (star + 0.5) / size).x;
    float core = (1.55 + 0.25 * log2(1.0 + coreDensity)) / (1.0 + 1.2 * r2)
               + 0.30 / (1.0 + 0.11 * r2) + 0.50 * exp(-0.55 * abs(disk - 4.9));
    gas *= 1.0 - 0.82 * exp(-0.5 * pow((disk - 6.1) / 2.4, 2.0));
    float corona = giantCorona(n, max(height, 0.0), giant.z, vent, t, seed);
    float field = 0.012 + gas + core + corona;
    return saturate(mix(0.80, field, smoothstep(-0.35, 0.4, height)));
}
