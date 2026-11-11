import Foundation

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
        func raw(_ w: Int, _ h: Int) -> [UInt8] {
            var u = comboUniforms(shape, 0, w: w, h: h)
            u.look.z = 1
            u.tune = SIMD4(0.5, 1, 0, 0)
            u.misc.w = 0
            u.setPalette(kPalettes[mono].1, colors: 5)
            return r.render(u, w: w, h: h) ?? []
        }
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
            gain > 0.6 && gain < 1.5
        ))
        out.append(("\(name) star sits at the view centre", big[((h / 2) * w + w / 2) * 4] > 200))
        var jump = 0, lit = 0
        for i in stride(from: 4, to: big.count, by: 4) where big[i] > 22 && i % (w * 4) != 0 {
            jump += abs(Int(big[i]) - Int(big[i - 4]))
            lit += 1
        }
        out.append(("\(name) sparse grains read as haze (step \(jump / max(lit, 1)))", lit > 0 && jump / lit < 8))
    }

    // grains trapped in the pressure bumps: face on, the annular profile has to
    // swing harder with the rings knob up than with it off
    func ringSwing(_ rings: Double) -> Double {
        let n = 256
        var u = comboUniforms(kParticleShapes[0], 0, w: n, h: n)
        u.setParams(kParticleShapes[0]) { $0.key == "inclination" ? 0 : $0.key == "rings" ? rings : $0.def }
        u.setPalette(kPalettes[mono].1, colors: 5)
        guard let px = DishRenderer(shader: kShaderPath)?.render(u, w: n, h: n) else { return 0 }
        var sum = [Double](repeating: 0, count: 40), cnt = sum
        for y in 0 ..< n {
            for x in 0 ..< n {
                let d = (Double(x - n / 2) * Double(x - n / 2) + Double(y - n / 2) * Double(y - n / 2)).squareRoot()
                let b = Int(d / 3)
                if b < 40 { sum[b] += Double(px[(y * n + x) * 4])
                    cnt[b] += 1
                }
            }
        }
        let prof = zip(sum, cnt).dropFirst(8).map { $0 / max($1, 1) }
        let mean = prof.reduce(0, +) / Double(prof.count)
        return (prof.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(prof.count)).squareRoot() / max(mean, 1)
    }
    let on = ringSwing(1), off = ringSwing(0)
    out.append((
        "protodisk pressure bumps trap grains into rings (swing \(String(format: "%.2f vs %.2f", on, off)))",
        on > off * 1.5
    ))
    return out
}
