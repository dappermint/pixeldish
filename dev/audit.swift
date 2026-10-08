import Foundation

// Audits kPalettes, dithers and settings for visually unpleasant results.
// Builds against the app's own renderer, so it cannot drift from what ships.
//
// The decisive checks are: which palette levels are reachable, and whether any
// pixel leaves the palette. A dither that invents colours is a bug, not a style.

func runAudit() -> Bool {
    guard let r = DishRenderer(shader: kShaderPath) else { return false }
    let W = 300, H = 190

    func render(
        shape: Int, dither: Int, pal: [SIMD3<Float>], colors: Int,
        grain: Float, vig: Float, invert: Bool, contrast: Float = 1.0,
        spread: Float = 0.0
    ) -> [UInt8] {
        var u = comboUniforms(shape, dither, w: W, h: H)
        u.look.w = Float(colors)
        u.tune = SIMD4(0.5, contrast, grain, vig)
        u.misc = SIMD4(2.1, invert ? 1 : 0, 12.5, spread)
        u.setPalette(pal, colors: colors)
        return r.render(u, w: W, h: H) ?? []
    }

    func lum(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    func analyse(_ px8: [UInt8], _ pal: [SIMD3<Float>], colors: Int) -> (off: Float, hits: [Int]) {
        var hits = [Int](repeating: 0, count: colors)
        var off = 0, total = 0
        for y in stride(from: 0, to: H, by: 2) {
            for x in stride(from: 0, to: W, by: 2) {
                let o = (y * W + x) * 4
                let c = SIMD3(Float(px8[o]) / 255, Float(px8[o + 1]) / 255, Float(px8[o + 2]) / 255)
                total += 1
                var matched = false
                for i in 0 ..< colors
                    where max(
                        abs(pal[i].x - c.x),
                        max(abs(pal[i].y - c.y), abs(pal[i].z - c.z))
                    ) < 0.03 {
                    hits[i] += 1
                    matched = true
                    break
                }
                if !matched { off += 1 }
            }
        }
        return (Float(off) / Float(total) * 100, hits)
    }

    var problems: [String] = []

    print("=== palette ramp (adjacent luminance steps must all be positive) ===")
    for (name, p) in kPalettes {
        let L = p.map(lum)
        let steps = (0 ..< 4).map { L[$0 + 1] - L[$0] }
        let mono = steps.allSatisfy { $0 > 0 }
        let mn = steps.min()!, mx = steps.max()!
        var note = ""
        if !mono { note = "  NON-MONOTONIC"
            problems.append("\(name): non-monotonic ramp")
        }
        if mn < 0.05 {
            note += "  step too small"
            problems.append("\(name): smallest step \(String(format: "%.3f", mn))")
        }
        if mx > 0.45 {
            note += "  step too harsh"
            problems.append("\(name): largest step \(String(format: "%.3f", mx))")
        }
        print(
            String(
                format: "  %-8@ %@ | %@  %@", name as NSString,
                L.map { String(format: "%.2f", $0) }.joined(separator: " ") as NSString,
                steps.map { String(format: "%+.2f", $0) }.joined(separator: " ") as NSString,
                (note.isEmpty ? "ok" : note) as NSString
            ))
    }

    print("\n=== adjacent hue jumps (two saturated entries far apart in hue shimmer) ===")
    func hueOf(_ c: SIMD3<Float>) -> Float? {
        let mx = max(c.x, max(c.y, c.z)), mn = min(c.x, min(c.y, c.z))
        let d = mx - mn
        if d < 1e-6 { return nil }
        let h: Float = mx == c.x ? (c.y - c.z) / d : (mx == c.y ? (c.z - c.x) / d + 2 : (c.x - c.y) / d + 4)
        return (h * 60).truncatingRemainder(dividingBy: 360)
    }
    func satOf(_ c: SIMD3<Float>) -> Float {
        let mx = max(c.x, max(c.y, c.z))
        return mx < 1e-6 ? 0 : (mx - min(c.x, min(c.y, c.z))) / mx
    }
    // signed shortest-path hue delta, so 355 degrees forward is read as 5 back
    func hueDelta(_ a: Float, _ b: Float) -> Float {
        var d = b - a
        while d > 180 {
            d -= 360
        }
        while d < -180 {
            d += 360
        }
        return d
    }
    for (name, p) in kPalettes {
        var deltas: [Float] = []
        for i in 0 ..< 4 {
            guard let h1 = hueOf(p[i]), let h2 = hueOf(p[i + 1]) else { continue }
            let d = hueDelta(h1, h2)
            // hue of a near-grey stop is invisible, so it cannot swing: theme
            // palettes end on an off-white whose hue is noise at 2% saturation
            if satOf(p[i]) > 0.15, satOf(p[i + 1]) > 0.15 { deltas.append(d) }
            let bothSat = satOf(p[i]) > 0.35 && satOf(p[i + 1]) > 0.35
            if abs(d) > 90, bothSat {
                problems.append("\(name): \(Int(abs(d)))° hue jump between entries \(i) and \(i + 1)")
                print(String(format: "  %-8@ %d-%d  %.0f°  SHIMMER RISK", name as NSString, i, i + 1, abs(d)))
            }
        }
        // a hue reversal makes the dither alternate between distant hues, which
        // reads as shimmer even when each step is small. under ~10 degrees a step
        // is wobble, not a direction, and a few degrees of wobble is invisible
        let signed = deltas.filter { abs($0) > 10 }
        if signed.count >= 2 {
            let pos = signed.filter { $0 > 0 }.count, neg = signed.filter { $0 < 0 }.count
            let swing = signed.max()! - signed.min()!
            if pos > 0, neg > 0, swing > 40 {
                problems.append("\(name): hue swings \(Int(swing))° back and forth mid-ramp")
                print(
                    String(
                        format: "  %-8@ hue deltas %@ -> SWING %.0f°", name as NSString,
                        deltas.map { String(format: "%.0f", $0) }.joined(separator: ",") as NSString, swing
                    ))
            }
        }
    }
    print("  (only flagged when both entries are saturated and >90°; Dusk's 66° cool-to-warm")
    print("   shift is deliberate, it is what that palette is for)")

    print("\n=== off-palette pixels (a dither must not invent colours) ===")
    print("Smooth is excluded: it is the un-dithered gradient, so interpolation is the point")
    for (name, p) in kPalettes {
        var worst: (String, Float) = ("", -1)
        for d in 1 ..< kDitherNames.count {
            let a = analyse(
                render(
                    shape: 0, dither: d, pal: p, colors: 5,
                    grain: 0.05, vig: 0.35, invert: false
                ), p, colors: 5
            )
            if a.off > worst.1 { worst = (kDitherNames[d], a.off) }
        }
        if worst.1 > 1.0 {
            problems.append("\(name)/\(worst.0): \(String(format: "%.1f", worst.1))% off-palette")
        }
        print(
            String(
                format: "  %-8@ worst=%-9@ %5.1f%%  %@", name as NSString, worst.0 as NSString,
                worst.1, (worst.1 > 1.0 ? "OFF-PALETTE" : "ok") as NSString
            ))
    }

    let dusk = kPalettes[1].1

    print("\n=== palette levels reachable per dither (5 colours, shape Flow) ===")
    for d in kDitherNames.indices {
        let a = analyse(
            render(
                shape: 0, dither: d, pal: dusk, colors: 5,
                grain: 0, vig: 0, invert: false
            ), dusk, colors: 5
        )
        let used = a.hits.filter { $0 > 0 }.count
        if used < 3 { problems.append("\(kDitherNames[d]): only \(used)/5 levels on Flow") }
        print(
            String(
                format: "  %-9@ %d/5  %@", kDitherNames[d] as NSString, used,
                a.hits.map { String($0) }.joined(separator: ",") as NSString
            ))
    }

    print("\n=== invert stays on-palette ===")
    for d in [1, 3, 5, 8, 9] {
        let a = analyse(
            render(
                shape: 0, dither: d, pal: dusk, colors: 5,
                grain: 0, vig: 0, invert: true
            ), dusk, colors: 5
        )
        if a.off > 1.0 { problems.append("invert/\(kDitherNames[d]): off-palette") }
        print(
            String(
                format: "  %-9@ off=%5.1f%%  %@", kDitherNames[d] as NSString, a.off,
                (a.off > 1.0 ? "OFF-PALETTE" : "ok") as NSString
            ))
    }

    print("\n=== 2 colours: exactly 2 rendered colours (Smooth excluded, it interpolates) ===")
    for d in 1 ..< kDitherNames.count {
        let px8 = render(
            shape: 0, dither: d, pal: kPalettes[2].1, colors: 2,
            grain: 0, vig: 0, invert: false
        )
        var seen = Set<UInt32>()
        for i in stride(from: 0, to: px8.count, by: 4) {
            seen.insert(UInt32(px8[i]) << 16 | UInt32(px8[i + 1]) << 8 | UInt32(px8[i + 2]))
        }
        if seen.count != 2 { problems.append("2col/\(kDitherNames[d]): \(seen.count) colours") }
        print(
            String(
                format: "  %-9@ %d colours  %@", kDitherNames[d] as NSString, seen.count,
                (seen.count == 2 ? "ok" : "WRONG") as NSString
            ))
    }

    print("\n=== settings sanity at the slider limits (shape Flow, Bayer8) ===")
    let grainMax = Float(kRanges["grain"]!.upperBound), vigMax = Float(kRanges["vignette"]!.upperBound)
    let cases: [(String, Float, Float, Bool, Float)] = [
        ("defaults", 0.05, 0.35, false, 1.0),
        ("grain max", grainMax, 0.35, false, 1.0),
        ("vignette max", 0.05, vigMax, false, 1.0),
        ("contrast min", 0.05, 0.35, false, Float(kRanges["contrast"]!.lowerBound)),
        ("contrast max", 0.05, 0.35, false, Float(kRanges["contrast"]!.upperBound)),
        ("invert", 0.05, 0.35, true, 1.0)
    ]
    for c in cases {
        let a = analyse(
            render(
                shape: 0, dither: 3, pal: dusk, colors: 5,
                grain: c.1, vig: c.2, invert: c.3, contrast: c.4
            ), dusk, colors: 5
        )
        let used = a.hits.filter { $0 > 0 }.count
        var note = "\(used)/5 levels"
        if used <= 2 { note += "  FLAT"
            problems.append("\(c.0): only \(used) levels")
        }
        if a.off > 1.0 { note += "  off-palette"
            problems.append("\(c.0): off-palette")
        }
        print(String(format: "  %-14@ off=%5.1f%%  %@", c.0 as NSString, a.off, note as NSString))
    }

    print("\n=== spread: narrow shapes should gain area in the end palette entries ===")
    print("(the dither already reaches all 5 levels, so measure how much area the extremes get)")
    let spreadMax = Float(kRanges["spread"]!.upperBound)
    for sh in [0, 6, 7] {
        let before = analyse(
            render(
                shape: sh, dither: 3, pal: dusk, colors: 5,
                grain: 0, vig: 0, invert: false
            ), dusk, colors: 5
        )
        let after = analyse(
            render(
                shape: sh, dither: 3, pal: dusk, colors: 5,
                grain: 0, vig: 0, invert: false, spread: spreadMax
            ), dusk, colors: 5
        )
        let tb = Double(before.hits.reduce(0, +)), ta = Double(after.hits.reduce(0, +))
        let eb = Double(before.hits[0] + before.hits[4]) / tb
        let ea = Double(after.hits[0] + after.hits[4]) / ta
        if ea <= eb { problems.append("\(kShapeNames[sh]): spread did not widen the range") }
        print(
            String(
                format: "  %-8@ extremes area  spread 0.0 = %.1f%%  spread %.1f = %.1f%%  %@",
                kShapeNames[sh] as NSString, eb * 100, spreadMax, ea * 100,
                (ea > eb ? "widened" : "NO CHANGE") as NSString
            ))
    }

    print("\n=== colour count must span the palette, not take its darkest N ===")
    for (name, p) in kPalettes {
        for c in [2, 3, 4] {
            let L = paletteSlots(p, colors: c).prefix(c).map(lum)
            let span = L.max()! - L.min()!
            if span < 0.5 {
                problems.append("\(name) at \(c) colours: luminance span only \(String(format: "%.2f", span))")
            }
            print(
                String(
                    format: "  %-8@ %d colours -> span %.2f  %@", name as NSString, c, span,
                    (span < 0.5 ? "TOO LOW CONTRAST" : "ok") as NSString
                ))
        }
    }

    print("\n=== summary ===")
    if problems.isEmpty { print("  no problems found") }
    for p in problems {
        print("  PROBLEM: \(p)")
    }
    return problems.isEmpty
}
