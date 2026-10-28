import CoreGraphics
import Foundation
import Metal

func runSelftest() -> Bool {
    Pref.register()
    var fails = 0
    var ran = 0
    func check(_ name: String, _ ok: Bool) {
        ran += 1
        if !ok { FileHandle.standardError.write(Data("FAIL \(name)\n".utf8))
            fails += 1
        }
    }
    check("shader exists", FileManager.default.fileExists(atPath: kShaderPath))
    let r = DishRenderer(shader: kShaderPath)
    check("renderer builds (device, shader, pipeline)", r != nil)
    check("atlas builds", r?.atlas != nil)
    if Bundle.main.bundlePath.hasSuffix(".app") {
        check("screen saver bundled", Bundle.main.url(forResource: "Pixeldish", withExtension: "saver") != nil)
    }
    // render every shape x dither offscreen and prove the pixels actually vary;
    // a broken generator silently returns one flat colour and looks like a bug in the palette
    if let r {
        for shape in kShapeNames.indices {
            for dither in kDitherNames.indices {
                let s = redStats(r.render(comboUniforms(shape, dither, w: 96, h: 64), w: 96, h: 64) ?? [])
                let label = "\(kShapeNames[shape])/\(kDitherNames[dither])"
                check("renders \(label) has range", Int(s.hi) - Int(s.lo) > 20)
                check("renders \(label) not blank", s.hi > 0 && s.lo < 255)
            }
        }
        // the Kerr trace outlives a frame, so moving a knob has to redo it:
        // after the change a warm renderer must still match a cold one
        var u = comboUniforms(kShapeNames.firstIndex(of: "Kerr") ?? 0, 3, w: 96, h: 64)
        _ = r.render(u, w: 96, h: 64)
        u.shp.0.y = 40
        u.misc.z += 7
        let warm = r.render(u, w: 96, h: 64)
        let cold = DishRenderer(shader: kShaderPath)?.render(u, w: 96, h: 64)
        check("kerr retraces when a knob moves", warm != nil && warm == cold)
    }

    check("shape names", kShapeNames.count == 20)
    if let r {
        for (name, ok) in kerrChecks(r.device) + pipesChecks(r) {
            check(name, ok)
        }
    }
    for (name, ok) in configChecks() {
        check(name, ok)
    }
    check("dither names", kDitherNames.count == 13)
    check(
        "steak icon is a rectangle of known inks",
        Set(kSteak.map(\.count)).count == 1
            && kSteak.joined().allSatisfy { $0 == "." || kSteakInk[$0] != nil }
    )
    check("palettes >= 20", kPalettes.count >= 20)
    let d0 = Pref.d.object(forKey: "contrast")
    Pref.d.set(2.5, forKey: "contrast")
    check("out-of-range pref clamps", prefValue("contrast") == Float(kRanges["contrast"]!.upperBound))
    if let d0 { Pref.d.set(d0, forKey: "contrast") } else { Pref.d.removeObject(forKey: "contrast") }
    let defaults = Pref.d.volatileDomain(forName: UserDefaults.registrationDomain)
    for (k, r) in kRanges {
        check("default \(k) inside its range", (defaults[k] as? Double).map(r.contains) == true)
    }
    check("palette names unique", Set(kPalettes.map(\.0)).count == kPalettes.count)
    check("palette by name", paletteIndex("Nord").map { kPalettes[$0].0 } == "Nord")
    let s0 = timeSeed(1_790_000_000), s1 = timeSeed(1_790_000_000.001)
    check("time seed in shader range", s0 >= 0 && s0 < 1_000 && s1 >= 0 && s1 < 1_000)
    check("time seed differs per ms", s0 != s1)
    check("time seed is deterministic", timeSeed(1_790_000_000) == s0)
    let look: [String: Any] = ["seed": s0, "paletteName": "Nord", "invert": true]
    let back = savedLooks(try? JSONSerialization.data(withJSONObject: [look]))
    check(
        "saved look round-trips",
        back.first?["seed"] as? Double == s0
            && back.first?["paletteName"] as? String == "Nord" && back.first?["invert"] as? Bool == true
    )
    for (name, p) in kPalettes {
        check("palette \(name) 5 colours", p.count == 5)
        check("palette \(name) in range", p.allSatisfy { $0.min() >= 0 && $0.max() <= 1 })
    }

    // photo palette: buckets are luminance-sorted slices, so the result must
    // come out monotonic even on pure noise. Runs against the real generator,
    // not a copy, because a mirrored version drifts and lies
    func greyRampImage() -> CGImage? {
        let w = 64, h = 64
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let v = UInt8((x * 255) / (w - 1))
                let o = (y * w + x) * 4
                px[o] = v
                px[o + 1] = v
                px[o + 2] = v
                px[o + 3] = 255
            }
        }
        return px.withUnsafeMutableBytes { buf -> CGImage? in
            guard
                let ctx = CGContext(
                    data: buf.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return nil }
            return ctx.makeImage()
        }
    }
    if let img = greyRampImage(), let pal = PhotoPalette.generate(from: img) {
        let lums = pal.map { 0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z }
        check("photo palette 5 stops", pal.count == 5)
        check(
            "photo palette monotonic",
            (0 ..< 4).allSatisfy { lums[$0] < lums[$0 + 1] }
        )
        check("photo palette spans range", lums[4] - lums[0] > 0.5)
    } else {
        check("photo palette generates", false)
    }

    let c0 = Pref.d.object(forKey: "customPalette"), n0 = kPalettes.count
    PhotoPalette.save([
        SIMD3(1, 1, 1),
        SIMD3(0, 0, 0),
        SIMD3(0.5, 0.5, 0.5),
        SIMD3(0.2, 0.2, 0.2),
        SIMD3(0.8, 0.8, 0.8)
    ])
    let custom = kPalettes.last
    check("custom palette appended", custom?.0 == "Custom")
    check(
        "custom palette sorted dark to light",
        custom.map { p in (0 ..< 4).allSatisfy { p.1[$0].x < p.1[$0 + 1].x } } == true
    )
    if let c0 { Pref.d.set(c0, forKey: "customPalette") } else { Pref.d.removeObject(forKey: "customPalette") }
    if n0 < kPalettes.count { kPalettes.removeLast() }

    if fails == 0 { print("selftest OK (\(ran) checks)") }
    return fails == 0
}

// the Kerr tracer against Bardeen's analytic shadow edge: rays 2% inside must fall
// in, 2% outside must escape, and the disk side turning toward us must be
// blueshifted. Runs the shader's own kerrRay through its kerrProbe kernel, not a copy
func kerrChecks(_ dev: MTLDevice) -> [(String, Bool)] {
    guard let fn = (try? dev.makeLibrary(URL: URL(fileURLWithPath: kShaderPath)))?.makeFunction(name: "kerrProbe"),
          let ps = try? dev.makeComputePipelineState(function: fn)
    else { return [("kerr probe builds", false)] }

    // spherical photon orbits of radius r land on the shadow edge at (alpha, beta)
    func edge(_ a: Double, _ inc: Double) -> [SIMD2<Double>] {
        if a ==
            0 {
            return (0 ..< 24).map { SIMD2(cos(Double($0) * .pi / 12), sin(Double($0) * .pi / 12)) * 27.0.squareRoot() }
        }
        return stride(from: 1.01, through: 4.5, by: 0.01).flatMap { r -> [SIMD2<Double>] in
            let lam = -(r * r * r - 3 * r * r + a * a * r + a * a) / (a * (r - 1))
            let eta = -r * r * r * (r * r * r - 6 * r * r + 9 * r - 4 * a * a) / (a * a * (r - 1) * (r - 1))
            let b2 = eta + a * a * cos(inc) * cos(inc) - lam * lam / (tan(inc) * tan(inc))
            return b2 > 0 ? [SIMD2(-lam / sin(inc), b2.squareRoot()), SIMD2(-lam / sin(inc), -b2.squareRoot())] : []
        }
    }
    var rays: [SIMD4<Float>] = []
    var groups: [(String, Range<Int>, (SIMD2<Float>) -> Bool)] = []
    func group(_ name: String, _ qs: [SIMD4<Float>], disk: SIMD2<Float>, _ ok: @escaping (SIMD2<Float>) -> Bool) {
        let lo = rays.count / 2
        for q in qs {
            rays += [q, SIMD4(disk.x, disk.y, 0, 0)]
        }
        groups.append((name, lo ..< rays.count / 2, ok))
    }
    for a in [0.0, 0.9, 0.998] {
        for deg in [60.0, 85.0] {
            let inc = deg * .pi / 180, pts = edge(a, inc)
            for (side, s, kind) in [("inside", 0.98, 0), ("outside", 1.02, 2)] {
                let qs = pts.map { SIMD4(Float(a), Float(inc), Float($0.x * s), Float($0.y * s)) }
                group("kerr a=\(a) i=\(Int(deg)) \(side) shadow edge", qs, disk: .zero) { Int($0.x) == kind }
            }
        }
    }
    let i80 = Float(80 * Double.pi / 180)
    group("kerr approaching disk side blueshifted", [SIMD4(0.9, i80, -10, -1)], disk: SIMD2(3, 30)) {
        $0.x == 1 && $0.y > 1
    }
    group("kerr receding disk side redshifted", [SIMD4(0.9, i80, 10, -1)], disk: SIMD2(3, 30)) { $0.x == 1 && $0.y < 1 }

    let n = rays.count / 2
    guard let qb = dev.makeBuffer(bytes: rays, length: rays.count * MemoryLayout<SIMD4<Float>>.stride),
          let ob = dev.makeBuffer(length: n * MemoryLayout<SIMD2<Float>>.stride),
          let cb = dev.makeCommandQueue()?.makeCommandBuffer(),
          let enc = cb.makeComputeCommandEncoder()
    else { return [("kerr probe runs", false)] }
    enc.setComputePipelineState(ps)
    enc.setBuffer(qb, offset: 0, index: 0)
    enc.setBuffer(ob, offset: 0, index: 1)
    // one thread per group: uniform dispatch works on CI's paravirtual GPU too
    enc.dispatchThreadgroups(
        MTLSize(width: n, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
    )
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    let out = ob.contents().bindMemory(to: SIMD2<Float>.self, capacity: n)
    return groups.map { g in (g.0, !g.1.isEmpty && g.1.allSatisfy { g.2(out[$0]) }) }
}

func configChecks() -> [(String, Bool)] {
    var out: [(String, Bool)] = []
    let kerr: [String: Any] = [
        "name": "gargantua", "shape": "kerr", "dither": "bayer 8", "palette": "Nord", "seed": 12.345,
        "params": ["spin": 0.99, "inclination": 84]
    ]
    let doc: [String: Any] = ["settings": ["animate": true], "pattern": withID(kerr), "saved": [withID(kerr)]]
    let text = KYAML.emit(doc)
    let back = (try? KYAML.parse(text)).map { KYAML.emit($0) }
    out.append(("kyaml round-trips", back == text))
    let nixStyle = """
    ---
    # what nix writes: quoted keys, trailing commas
    {"pattern": {"shape": "Torus", "params": {"windings": 9,},}, "saved": [], }
    """
    let n = try? KYAML.parse(nixStyle) as? [String: Any]
    out.append((
        "kyaml reads quoted keys and comments",
        (n?["pattern"] as? [String: Any])?["shape"] as? String == "Torus"
    ))
    var line = ""
    do { _ = try KYAML.parse("{\n  a: 1,\n  b: }") } catch { line = "\(error)" }
    out.append(("kyaml errors name the line", line.hasPrefix("line 3")))

    let p = normalizePattern(kerr)
    out.append(("pattern names are canonical", p["shape"] as? String == "Kerr" && p["dither"] as? String == "Bayer 8"))
    out.append((
        "pattern fills missing params",
        (p["params"] as? [String: Any])?["disk"] as? Double == 20 &&
            (p["params"] as? [String: Any])?["spin"] as? Double == 0.99
    ))
    let legacy = normalizePattern(["shape": 16, "dither": 3, "palette": 0, "paletteName": "Nord", "warp": 7.0])
    out.append((
        "legacy looks map indices to names",
        legacy["shape"] as? String == "Kerr" && legacy["palette"] as? String == "Nord"
    ))
    out.append(("pattern clamps out of range", legacy["warp"] as? Double == 1))

    let id = patternID(kerr)
    var renamed = kerr, reseeded = kerr
    renamed["name"] = "other"
    reseeded["seed"] = 12.346
    out.append(("pattern id is a v5 uuid", UUID(uuidString: id) != nil && Array(id)[14] == "5"))
    out.append(("pattern id ignores the name", patternID(renamed) == id))
    out.append(("pattern id follows the content", patternID(reseeded) != id))
    out.append((
        "pattern id survives kyaml",
        (try? KYAML.parse(KYAML.emit(kerr, line: true)) as? [String: Any]).map(patternID) == id
    ))
    out.append((
        "check flags typos",
        patternProblems(["shape": "kerrr"]).count == 1
            && patternProblems(["shape": "Kerr", "params": ["spinn": 1]]).count == 1
            && patternProblems(kerr).isEmpty
    ))
    return out
}

func pipesChecks(_ r: DishRenderer) -> [(String, Bool)] {
    var out: [(String, Bool)] = []
    let m = r.pipes.meshes
    out.append((
        "pipes meshes built (cyl, sph, elb, teapot)",
        !m.cyl.isEmpty && !m.sph.isEmpty && !m.elb.isEmpty && m.tea.count == 9_408
    ))

    var zeroCollisions = true, denseEnough = true
    for cycle in 0 ..< 8 {
        let sc = PipeScene.simulate(seed: Float(cycle) * 17.3, cycle: cycle, aspect: 1.54, jointMode: 1)
        if sc.collisions != 0 { zeroCollisions = false }
        if sc.prims.count < 100 || Set(sc.prims.map(\.mat)).count < 2 { denseEnough = false }
    }
    out.append(("pipes 3d grid is collision-free", zeroCollisions))
    out.append(("pipes scene spawns multi-colour network", denseEnough))

    let sElb = PipeScene.simulate(seed: 2.1, cycle: 1, aspect: 1.5, jointMode: 0)
    let sMix = PipeScene.simulate(seed: 2.1, cycle: 1, aspect: 1.5, jointMode: 1)
    let sBal = PipeScene.simulate(seed: 2.1, cycle: 1, aspect: 1.5, jointMode: 2)
    func countJoints(_ s: PipeScene) -> (elb: Int, ball: Int) {
        var e = 0, b = 0
        for p in s.prims {
            if case .elb = p.kind { e += 1 }
            if case .ball = p.kind { b += 1 }
        }
        return (e, b)
    }
    let j0 = countJoints(sElb), j1 = countJoints(sMix), j2 = countJoints(sBal)
    out.append((
        "pipes joint modes (elbows, mixed, spheres)",
        j0.elb > 0 && j0.ball == 0 && j1.elb > 0 && j1.ball > 0 && j2.elb == 0 && j2.ball > 0
    ))

    let idx = kShapeNames.firstIndex(of: "Pipes") ?? 19
    let W = 240, H = 160
    var u = comboUniforms(idx, 3, w: W, h: H)
    if let vh = paletteIndex("Van Helsing") { u.setPalette(kPalettes[vh].1, colors: 5) }
    if let px = r.render(u, w: W, h: H) {
        var buckets = Set<Int>()
        for i in stride(from: 0, to: px.count, by: 4) {
            let rv = Int(px[i]), gv = Int(px[i + 1]), bv = Int(px[i + 2])
            let mx = max(rv, max(gv, bv)), mn = min(rv, min(gv, bv))
            if mx - mn > 50 {
                let b = rv == mx ? (gv > bv + 30 ? 0 : 1) : (gv == mx ? (bv > rv + 30 ? 2 : 3) : 4)
                buckets.insert(b)
            }
        }
        out.append(("pipes renders multiple distinct pipe hues", buckets.count >= 3))
    } else {
        out.append(("pipes renders multiple distinct pipe hues", false))
    }

    if let mono = paletteIndex("Mono") {
        u.setPalette(kPalettes[mono].1, colors: 5)
        if let px = r.render(u, w: W, h: H) {
            var neutral = true
            for i in stride(from: 0, to: px.count, by: 4) {
                let rv = Int(px[i]), gv = Int(px[i + 1]), bv = Int(px[i + 2])
                if max(abs(rv - gv), abs(gv - bv)) > 8 { neutral = false
                    break
                }
            }
            out.append(("pipes stays greyscale on Mono palette", neutral))
        } else {
            out.append(("pipes stays greyscale on Mono palette", false))
        }
    }
    out.append((
        "pipes frame rate follows the slider, eases with cover, hyper and other shapes untouched",
        targetFPS(shape: idx, isPhoto: false, hyper: false) == 60
            && targetFPS(shape: idx, isPhoto: false, hyper: false, fps: 120) == 120
            && targetFPS(shape: idx, isPhoto: false, hyper: false, fps: 120, maxFPS: 60) == 60
            && targetFPS(shape: idx, isPhoto: false, hyper: false, fps: 120, visible: 0.5) == 60
            && targetFPS(shape: idx, isPhoto: false, hyper: false, fps: 60, visible: 0) == 10
            && targetFPS(shape: idx, isPhoto: false, hyper: true, fps: 30, visible: 0.1, maxFPS: 120) == 120
            && targetFPS(shape: idx, isPhoto: true, hyper: false) == 20
            && targetFPS(shape: 0, isPhoto: false, hyper: false, fps: 120) == 20
            && targetFPS(shape: 0, isPhoto: false, hyper: true, maxFPS: 120) == 120
    ))
    let scr = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
    out.append((
        "visible share: bare, half covered, overlapping windows counted once, fully covered",
        visibleShare(scr, covers: []) == 1
            && abs(visibleShare(scr, covers: [CGRect(x: 0, y: 0, width: 800, height: 1_000)]) - 0.5) < 0.01
            && abs(visibleShare(scr, covers: [
                CGRect(x: 0, y: 0, width: 800, height: 1_000), CGRect(x: 400, y: 0, width: 400, height: 1_000)
            ]) - 0.5) < 0.01
            && visibleShare(scr, covers: [scr.insetBy(dx: -10, dy: -10)]) == 0
    ))
    return out
}
