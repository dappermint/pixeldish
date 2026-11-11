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

    return out + diskGravityChecks(r) + diskStructureChecks()
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
    guard d.ensure(count: 1, w: 16, h: 16, isDisk: true), let field = d.field,
          let grain = r.device.makeBuffer(length: 32, options: .storageModeShared),
          let cb = r.queue.makeCommandBuffer()
    else { return [("disk field renders", false)] }
    let at = grain.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2)
    at[0] = SIMD4((Float(cx) + 0.5) * dx - 3.6, 0, (Float(cy) + 0.5) * dx - 3.6, 0)
    at[1] = .zero
    d.particles = grain
    var pu = ParticleUniforms()
    pu.shp0.y = 1
    pu.deposit = 1
    d.fieldPasses(cb, &pu, 1)
    cb.commit()
    cb.waitUntilCompleted()
    var px = [UInt16](repeating: 0, count: n * n * 4)
    field.getBytes(&px, bytesPerRow: n * 8, from: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0)

    var out: [(String, Bool)] = []
    // the rings reach every level of the pyramid. the far ones are arcs inside the grid, where the
    // error of standing a grain at its cell's centre no longer averages out, hence the slack
    for (ring, slack) in [(16, Float(0.04)), (64, 0.12), (160, 0.25)] {
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
            abs(pull - 1) < slack && abs(side) < slack
        ))
    }
    return out
}

// the forces have to make the structure: face on, the brightness around each annulus
// swings harder with the disk's gravity and the planets on than with both off
private func diskStructureChecks() -> [(String, Bool)] {
    func swing(_ on: Bool) -> Double {
        let n = 1_024, shape = kParticleShapes[0]
        var u = rawUniforms(shape, w: n, h: n)
        u.setParams(shape) { $0.key == "inclination" || (!on && ["mass", "planet"].contains($0.key)) ? 0 : $0.def }
        guard let fresh = DishRenderer(shader: kShaderPath) else { return 0 }
        fresh.particles.warm = 1_500
        guard let px = fresh.render(u, w: n, h: n) else { return 0 }
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
    return [(
        "protodisk grows arms and wakes from gravity (swing \(String(format: "%.3f vs %.3f", on, off)))",
        on > off * 2
    )]
}
