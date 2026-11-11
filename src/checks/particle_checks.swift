import Foundation
import Metal
import simd

func particleChecks(_ r: DishRenderer) -> [(String, Bool)] {
    var out: [(String, Bool)] = []
    let mono = paletteIndex("Mono") ?? 0
    for shape in kParticleShapes {
        let name = shapeName(shape).lowercased()
        let u = comboUniforms(shape, 0, w: 128, h: 96)
        let a = DishRenderer(shader: kShaderPath)?.render(u, w: 128, h: 96)
        let b = DishRenderer(shader: kShaderPath)?.render(u, w: 128, h: 96)
        out.append(("\(name) cold renders match", a != nil && a == b))
        var later = u
        later.misc.z += 2
        _ = r.render(u, w: 128, h: 96)
        let moved = r.render(later, w: 128, h: 96)
        out.append(("\(name) moves as the clock runs", moved != nil && moved != a))
    }

    // the same exposure on a small and a large display, a star at the centre of the
    // view, and sparse grains that read as haze instead of speckle
    for shape in kParticleShapes {
        func raw(_ w: Int, _ h: Int) -> [UInt8] { r.render(rawUniforms(shape, w: w, h: h), w: w, h: h) ?? [] }
        let name = shapeName(shape).lowercased(), w = 1_600, h = 1_000
        let small = raw(w / 4, h / 4), big = raw(w, h)
        guard !small.isEmpty, !big.isEmpty else {
            out.append(("\(name) renders at two sizes", false))
            continue
        }
        let black = Int(kPalettes[mono].1[0].x * 255)
        let gain = Double(redStats(big).mean - black) / Double(max(redStats(small).mean - black, 1))
        out.append((
            "\(name) exposure holds across display sizes (x\(String(format: "%.2f", gain)))",
            gain > 0.65 && gain < 1.25
        ))
        out.append(("\(name) star sits at the view centre", big[((h / 2) * w + w / 2) * 4] > 200))
        var jump = 0, lit = 0
        for i in stride(from: 4, to: big.count, by: 4) where big[i] > 22 && i % (w * 4) != 0 {
            jump += abs(Int(big[i]) - Int(big[i - 4]))
            lit += 1
        }
        out.append(("\(name) sparse grains read as haze (step \(jump / max(lit, 1)))", lit > 0 && jump / lit < 8))
    }

    return out + diskGravityChecks(r) + diskFlowChecks(r) + diskDustChecks() + diskStructureChecks()
}

// mono palette, no dither, grain or vignette: the red channel is the field
private func rawUniforms(_ shape: Int, w: Int, h: Int) -> Uniforms {
    var u = comboUniforms(shape, 0, w: w, h: h)
    u.look.z = 1
    u.tune = SIMD4(0.5, 1, 0, 0)
    u.misc.w = 0
    u.setPalette(kPalettes[paletteIndex("Mono") ?? 0].1, colors: 5)
    return u
}

private func half(_ h: UInt16) -> Float {
    let e = Int(h >> 10) & 31, m = Float(h & 1_023), s: Float = h >> 15 == 0 ? 1 : -1
    return e == 0 ? s * m * 0x1p-24 : s * (1 + m / 1_024) * Float(sign: .plus, exponent: e - 15, significand: 1)
}

// one grain holding the whole disk's mass: around it the field read back from the grid has
// to point at the grain and add up to the softened point mass the pyramid stands for
private func diskGravityChecks(_ r: DishRenderer) -> [(String, Bool)] {
    let d = r.particles, n = 256, cx = 60, cy = 70, dx = 7.2 / Float(n)
    d.clear()
    defer { d.clear() }
    guard d.ensure(count: 1, w: 16, h: 16, isDisk: true), let field = d.field, let bodies = d.bodies,
          let grain = r.device.makeBuffer(length: 32, options: .storageModeShared),
          let cb = r.queue.makeCommandBuffer()
    else { return [("disk field renders", false)] }
    // a massless planet at rest 40 cells from the grain, to see the disk pull on it
    let planet = at0(cx, cy, dx) + 40 * dx * SIMD2<Float>(0.76, 0.65)
    let body = bodies.contents().bindMemory(to: SIMD4<Float>.self, capacity: 6)
    for (i, pos) in [planet, SIMD2(0, 2), SIMD2(2, 0)].enumerated() {
        body[2 * i] = SIMD4(pos.x, pos.y, 0, 0)
        body[2 * i + 1] = SIMD4(1, 1, 0, 0)
    }
    let at = grain.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2)
    at[0] = SIMD4(at0(cx, cy, dx).x, 0, at0(cx, cy, dx).y, 0)
    at[1] = .zero
    d.particles = grain
    var pu = ParticleUniforms()
    pu.shp0.y = 1
    pu.deposit = 1
    pu.dt = 0.01
    d.fieldPasses(cb, &pu, 1)
    d.moveBodies(cb, &pu)
    cb.commit()
    cb.waitUntilCompleted()
    var px = [UInt16](repeating: 0, count: n * n * 4)
    field.getBytes(&px, bytesPerRow: n * 8, from: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0)

    var out: [(String, Bool)] = []
    // the rings reach every level of the pyramid; the far one is only an arc inside the grid
    for ring in [16, 64, 160] {
        var pull: Float = 0, side: Float = 0, hits: Float = 0
        for k in 0 ..< 64 {
            let a = Float(k) * .pi / 32
            let tx = cx + Int((Float(ring) * cos(a)).rounded()), ty = cy + Int((Float(ring) * sin(a)).rounded())
            guard (0 ..< n).contains(tx), (0 ..< n).contains(ty) else { continue }
            hits += 1
            let off = SIMD2(Float(cx - tx), Float(cy - ty)) * dx, len = length(off)
            let acc = SIMD2(half(px[(ty * n + tx) * 4]), half(px[(ty * n + tx) * 4 + 1]))
            let want = len / pow(len * len + 0.001_6, 1.5)
            pull += dot(acc, off / len) / want
            side += (acc.x * off.y - acc.y * off.x) / len / want
        }
        pull /= max(hits, 1)
        side /= max(hits, 1)
        out.append((
            "disk self-gravity matches a point mass \(ring) cells out (x\(String(format: "%.3f", pull)), "
                + "sideways \(String(format: "%+.3f", side)))",
            abs(pull - 1) < 0.02 && abs(side) < 0.02
        ))
    }
    let off = at0(cx, cy, dx) - planet, star = -planet / pow(length(planet), 3)
    let want = off / pow(length_squared(off) + 0.001_6, 1.5)
    let got = SIMD2(body[0].z, body[0].w) / pu.dt - star
    let miss = length(got - want) / length(want)
    out.append(("planets feel the disk's pull (off by \(String(format: "%.3f", miss)))", miss < 0.05))
    return out
}

private func at0(_ cx: Int, _ cy: Int, _ dx: Float) -> SIMD2<Float> {
    SIMD2((Float(cx) + 0.5) * dx - 3.6, (Float(cy) + 0.5) * dx - 3.6)
}

// a ring of grains on circular orbits: the mean flow the field hands back on the ring has to be
// the ring's own, or the cooling that relaxes every grain toward it makes or loses angular
// momentum. averaging velocities as vectors shortens them where the ring curves
private func diskFlowChecks(_ r: DishRenderer) -> [(String, Bool)] {
    let d = r.particles, n = 256, count = 4_096, ring: Float = 0.5
    d.clear()
    defer { d.clear() }
    guard d.ensure(count: count, w: 16, h: 16, isDisk: true), let field = d.field,
          let buf = r.device.makeBuffer(length: count * 32, options: .storageModeShared),
          let cb = r.queue.makeCommandBuffer()
    else { return [("disk flow renders", false)] }
    let ps = buf.contents().bindMemory(to: SIMD4<Float>.self, capacity: count * 2)
    for i in 0 ..< count {
        let a = Float(i) / Float(count) * 2 * .pi, v = 1 / ring.squareRoot()
        ps[2 * i] = SIMD4(ring * cos(a), 0, ring * sin(a), 0)
        ps[2 * i + 1] = SIMD4(-v * sin(a), 0, v * cos(a), 0)
    }
    d.particles = buf
    var pu = ParticleUniforms()
    pu.deposit = 1 / Float(count)
    d.fieldPasses(cb, &pu, count)
    cb.commit()
    cb.waitUntilCompleted()
    var px = [Float16](repeating: 0, count: n * n * 4)
    field.getBytes(&px, bytesPerRow: n * 8, from: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0)
    var worst: Float = 0
    for y in 0 ..< n {
        for x in 0 ..< n {
            let at = at0(x, y, 7.2 / Float(n))
            guard abs(length(at) - ring) < 0.01 else { continue }
            let vr = Float(px[(y * n + x) * 4 + 2]), j = Float(px[(y * n + x) * 4 + 3])
            worst = max(worst, abs(vr), abs(j / ring.squareRoot() - 1))
        }
    }
    return [(
        "the gas's mean flow on a circular ring is the ring's own (off by \(String(format: "%.4f", worst)))",
        worst < 0.003
    )]
}

// dust feels the gas as a headwind, because pressure holds the gas up and not the dust, so it
// has to spiral inward while the gas stays put. gravity and the planets are off: arms stir
// both far harder than the drift
private func diskDustChecks() -> [(String, Bool)] {
    let n = 1_024, shape = kParticleShapes[0]
    var u = rawUniforms(shape, w: n, h: n)
    u.setParams(shape) { ["inclination", "mass", "planet"].contains($0.key) ? 0 : $0.def }
    let count = Int(Float(n * n) * u.shp.1.x)
    guard let fresh = DishRenderer(shader: kShaderPath),
          let buf = fresh.device.makeBuffer(length: count * 32, options: .storageModeShared)
    else { return [("dust check renders", false)] }
    fresh.particles.particles = buf
    fresh.particles.warm = 600
    guard fresh.render(u, w: n, h: n) != nil else { return [("dust check renders", false)] }
    let ps = buf.contents().bindMemory(to: SIMD4<Float>.self, capacity: count * 2)
    var drift = [Float](repeating: 0, count: 2), hits = drift
    for i in 0 ..< count {
        let x = SIMD2(ps[2 * i].x, ps[2 * i].z), v = SIMD2(ps[2 * i + 1].x, ps[2 * i + 1].z), r = length(x)
        guard r > 1, r < 2.4 else { continue }
        let kind = Float(i % 64) < 64 * u.shp.1.y ? 0 : 1
        drift[kind] += dot(x, v) / r
        hits[kind] += 1
    }
    let dust = drift[0] / max(hits[0], 1), gas = drift[1] / max(hits[1], 1)
    return [(
        "dust drifts inward through the gas (radial speed \(String(format: "%+.4f vs %+.4f", dust, gas)))",
        dust < gas - 0.001 && dust > gas - 0.004
    )]
}

// the forces have to make the structure: face on, the brightness around each annulus
// swings harder with the disk's gravity and the planets on than with both off
private func diskStructureChecks() -> [(String, Bool)] {
    // how far the worst planet's orbit has moved from where it was seeded
    var strayed: Float = 0
    func swing(_ on: Bool) -> Double {
        let n = 1_024, shape = kParticleShapes[0]
        var u = rawUniforms(shape, w: n, h: n)
        u.setParams(shape) { $0.key == "inclination" || (!on && ["mass", "planet"].contains($0.key)) ? 0 : $0.def }
        guard let fresh = DishRenderer(shader: kShaderPath) else { return 0 }
        fresh.particles.warm = 1_500
        guard let px = fresh.render(u, w: n, h: n), let bodies = fresh.particles.bodies else { return 0 }
        if on {
            let b = bodies.contents().bindMemory(to: SIMD4<Float>.self, capacity: 6)
            strayed = (0 ..< 3).map { i -> Float in
                let x = SIMD2(b[2 * i].x, b[2 * i].y), v = SIMD2(b[2 * i].z, b[2 * i].w)
                return abs(1 / (2 / length(x) - length_squared(v)) / b[2 * i + 1].x - 1)
            }.max() ?? 0
        }
        var sum = [[Double]](repeating: [Double](repeating: 0, count: 36), count: 19), cnt = sum
        for y in 0 ..< n {
            for x in 0 ..< n {
                let ex = Double(x - n / 2), ey = Double(y - n / 2),
                    ring = Int((ex * ex + ey * ey).squareRoot() / 20) - 6
                guard ring >= 0, ring < 19 else { continue }
                let sector = min(Int((atan2(ey, ex) + .pi) / (2 * .pi) * 36), 35)
                sum[ring][sector] += Double(px[(y * n + x) * 4])
                cnt[ring][sector] += 1
            }
        }
        return zip(sum, cnt).map { s, c -> Double in
            let v = zip(s, c).map { $0 / max($1, 1) }, mean = v.reduce(0, +) / 36
            return (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 36).squareRoot() / max(mean, 1)
        }.reduce(0, +) / 19
    }
    let on = swing(true), off = swing(false)
    return [
        (
            "protodisk grows arms and wakes from gravity (swing \(String(format: "%.3f vs %.3f", on, off)))",
            on > off * 2
        ),
        // the disk moves the planets, but a step that lets the grains lead them tows them out of it
        ("the disk does not fling its planets (orbits moved \(String(format: "%.2f", strayed)))", strayed < 0.25)
    ]
}
