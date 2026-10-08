import CoreGraphics
import Foundation

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
    }

    check("shape names", kShapeNames.count == 15)
    check("dither names", kDitherNames.count == 10)
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

    if fails == 0 { print("selftest OK (\(ran) checks)") }
    return fails == 0
}
