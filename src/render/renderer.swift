import AppKit
import ImageIO
import Metal
import MetalKit
import UniformTypeIdentifiers

let kShapeNames = [
    "Drift", "Shepard", "Sines", "Fringe", "Curtain", "Voronoi",
    "Contour", "Vortex", "Sweep", "Glitch", "Twill", "Belts", "Circuit",
    "Julia", "Kali", "Torus", "Kerr", "Binary", "Cygnus"
]
let kDitherNames = [
    "Smooth", "Poster", "Bayer 4", "Bayer 8", "Noise",
    "Halftone", "Lines", "Diamond", "ASCII", "Benday",
    "Bayer 2", "Bayer 16", "R2"
]

struct ShapeParam {
    let key: String, label: String, range: ClosedRange<Double>, def: Double
}

// knobs one shape has beyond the shared ones, packed into Uniforms.shp in this
// order. Keyed by name like the palettes, so appending a shape moves nothing
let kShapeParams: [String: [ShapeParam]] = [
    "Torus": [
        ShapeParam(key: "size", label: "Size", range: 0.5 ... 1.5, def: 1),
        ShapeParam(key: "thickness", label: "Thickness", range: 0.1 ... 0.45, def: 0.25),
        ShapeParam(key: "tumble", label: "Tumble", range: 0 ... 3, def: 1),
        ShapeParam(key: "chase", label: "Chase", range: 0 ... 3, def: 1),
        ShapeParam(key: "windings", label: "Windings", range: 1 ... 12, def: 6)
    ],
    "Kerr": [
        ShapeParam(key: "spin", label: "Spin", range: 0 ... 0.998, def: 0.9),
        ShapeParam(key: "inclination", label: "Inclination", range: 5 ... 89, def: 80),
        ShapeParam(key: "mass", label: "Mass", range: 0.5 ... 2, def: 1),
        ShapeParam(key: "temperature", label: "Disk temperature", range: 0.5 ... 2, def: 1),
        ShapeParam(key: "disk", label: "Disk radius", range: 8 ... 30, def: 20)
    ],
    "Binary": [
        ShapeParam(key: "massRatio", label: "Mass ratio", range: 0.1 ... 1, def: 0.7),
        ShapeParam(key: "separation", label: "Separation", range: 16 ... 50, def: 34),
        ShapeParam(key: "inclination", label: "Inclination", range: 30 ... 89, def: 75),
        ShapeParam(key: "orbit", label: "Orbit speed", range: 0 ... 3, def: 1),
        ShapeParam(key: "temperature", label: "Disk temperature", range: 0.5 ... 2, def: 1)
    ],
    "Cygnus": [
        ShapeParam(key: "starMass", label: "Star mass", range: 1 ... 4, def: 2),
        ShapeParam(key: "inclination", label: "Inclination", range: 30 ... 89, def: 70),
        ShapeParam(key: "orbit", label: "Orbit speed", range: 0 ... 3, def: 1),
        ShapeParam(key: "stream", label: "Stream", range: 0 ... 1, def: 0.5),
        ShapeParam(key: "temperature", label: "Disk temperature", range: 0.5 ... 2, def: 1)
    ]
]

func shapeName(_ i: Int) -> String { kShapeNames[min(max(i, 0), kShapeNames.count - 1)] }
func shapeParams(_ shape: Int) -> [ShapeParam] { kShapeParams[shapeName(shape)] ?? [] }
func paramKey(_ shape: Int, _ p: ShapeParam) -> String { "\(shapeName(shape).lowercased()).\(p.key)" }

struct Uniforms {
    var look: SIMD4<Float> = .zero
    var tune: SIMD4<Float> = .zero
    var misc: SIMD4<Float> = .zero
    var view: SIMD4<Float> = .zero
    var pal: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
        (.zero, .zero, .zero, .zero, .zero)
    var shp: (SIMD4<Float>, SIMD4<Float>) = (.zero, .zero)

    mutating func setParams(_ shape: Int, _ value: (ShapeParam) -> Double) {
        var v = shapeParams(shape).map { p in Float(min(max(value(p), p.range.lowerBound), p.range.upperBound)) }
        v += [Float](repeating: 0, count: 8 - v.count)
        shp = (SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]))
    }
}

// one place that turns prefs into shader uniforms; export and the live layer
// must agree or the exported PNG will not match the screen
func makeUniforms(w: Int, h: Int, time: Float) -> Uniforms {
    let d = Pref.d
    var u = Uniforms()
    u.look = SIMD4(
        Float(d.integer(forKey: "shape")), Float(d.integer(forKey: "dither")),
        prefValue("pixelSize"), Float(d.integer(forKey: "colors"))
    )
    u.tune = SIMD4(prefValue("warp"), prefValue("contrast"), prefValue("grain"), prefValue("vignette"))
    u.misc = SIMD4(
        Float(d.double(forKey: "seed")), d.bool(forKey: "invert") ? 1 : 0,
        time, prefValue("spread")
    )
    u.view = SIMD4(
        Float(w), Float(h), prefValue("zoom"),
        d.bool(forKey: "isPhoto") ? 1 : 0
    )
    u.setPalette(
        kPalettes[min(max(d.integer(forKey: "palette"), 0), kPalettes.count - 1)].1,
        colors: d.integer(forKey: "colors")
    )
    let shape = d.integer(forKey: "shape")
    u.setParams(shape) { d.object(forKey: paramKey(shape, $0)) == nil ? $0.def : d.double(forKey: paramKey(shape, $0)) }
    return u
}

// N colours must span the whole palette, not take its darkest N entries:
// taking the first N made 2 colours a near-invisible dark-on-dark pair
func paletteSlots(_ pal: [SIMD3<Float>], colors: Int) -> [SIMD3<Float>] {
    let n = min(max(colors, 2), pal.count)
    return (0 ..< 5).map { i in
        pal[min(Int((Double(i) * Double(pal.count - 1) / Double(n - 1)).rounded()), pal.count - 1)]
    }
}

extension Uniforms {
    mutating func setPalette(_ p: [SIMD3<Float>], colors: Int) {
        let s = paletteSlots(p, colors: colors).map { SIMD4($0, 1) }
        pal = (s[0], s[1], s[2], s[3], s[4])
    }
}

// the fixed settings the selftest and audit render every shape x dither with
func comboUniforms(_ shape: Int, _ dither: Int, w: Int, h: Int) -> Uniforms {
    var u = Uniforms()
    u.look = SIMD4(Float(shape), Float(dither), 3, 5)
    u.tune = SIMD4(0.5, 1, 0.05, 0.35)
    u.misc = SIMD4(2.1, 0, 12.5, 0.12)
    u.view = SIMD4(Float(w), Float(h), 1, 0)
    u.setPalette(kPalettes[1].1, colors: 5)
    u.setParams(shape) { $0.def }
    return u
}

func cgImage(_ px: [UInt8], w: Int, h: Int) -> CGImage? {
    var px = px
    return CGContext(
        data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )?.makeImage()
}

// red channel only: enough to tell a drawn frame from a flat or blank one
func redStats(_ px: [UInt8]) -> (lo: UInt8, hi: UInt8, mean: Int) {
    var lo: UInt8 = 255, hi: UInt8 = 0, sum = 0
    for i in stride(from: 0, to: px.count, by: 4) {
        lo = min(lo, px[i])
        hi = max(hi, px[i])
        sum += Int(px[i])
    }
    return (lo, hi, sum / max(px.count / 4, 1))
}

func writePNG(_ img: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dest, img, nil)
    return CGImageDestinationFinalize(dest)
}

final class DishRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let tracer: MTLRenderPipelineState
    var atlas: MTLTexture?
    var photo: MTLTexture?
    // Kerr's geodesics never depend on the clock, only on these, so they are
    // traced into `trace` once per change instead of every frame
    var trace: MTLTexture?
    var traceKey: [Float] = []
    var start = Date()
    var paused = false
    // PIXELDISH_PROBE reads the live drawable back for a few frames; used by
    // `just test-live` to prove the window path draws, since the display itself
    // cannot be screenshotted without screen-recording permission
    var probeFrames = 0
    // the clock the live view draws at; stills use it too so they match the screen
    var now: Float { paused ? 0 : Float(Date().timeIntervalSince(start)) * prefValue("speed") }

    init?(shader path: String) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue()
        else { return nil }
        device = dev
        queue = q
        guard let lib = try? dev.makeLibrary(URL: URL(fileURLWithPath: path)),
              let vf = lib.makeFunction(name: "vmain"),
              let ff = lib.makeFunction(name: "fmain"),
              let kf = lib.makeFunction(name: "ktrace")
        else {
            FileHandle.standardError.write(Data("pixeldish: shader load failed\n".utf8))
            return nil
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vf
        pd.fragmentFunction = ff
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        guard let p = try? dev.makeRenderPipelineState(descriptor: pd) else { return nil }
        pd.fragmentFunction = kf
        pd.colorAttachments[0].pixelFormat = .rg32Float
        guard let t = try? dev.makeRenderPipelineState(descriptor: pd) else { return nil }
        pipeline = p
        tracer = t
        super.init()
        atlas = makeRampAtlas(dev)
    }

    func retrace(_ cb: MTLCommandBuffer, _ u: Uniforms) {
        guard Int(u.look.x) == kShapeNames.firstIndex(of: "Kerr"), u.view.w < 0.5 else {
            trace = nil
            traceKey = []
            return
        }
        let key = [u.view.x, u.view.y, u.view.z, u.misc.x, u.shp.0.x, u.shp.0.y, u.shp.0.z, u.shp.1.x]
        guard key != traceKey else { return }
        let w = Int(u.view.x), h = Int(u.view.y)
        if trace?.width != w || trace?.height != h {
            // ponytail: full floats cost ~80 MB on a 4K panel; rg16Float halves it but bands the outer disk
            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rg32Float,
                width: w, height: h, mipmapped: false
            )
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = .private
            trace = device.makeTexture(descriptor: td)
        }
        guard let t = trace else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = t
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        var u = u
        enc.setRenderPipelineState(tracer)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        traceKey = key
    }

    func encode(_ cb: MTLCommandBuffer, _ rp: MTLRenderPassDescriptor, _ u: Uniforms) -> Bool {
        retrace(cb, u)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return false }
        var u = u
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(photo, index: 0)
        enc.setFragmentTexture(atlas, index: 1)
        enc.setFragmentTexture(trace, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        return true
    }

    // offscreen RGBA8 render; export, --capture, the selftest and the audit all go through here
    func render(_ u: Uniforms, w: Int, h: Int) -> [UInt8]? {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: w, height: h, mipmapped: false
        )
        td.usage = [.renderTarget, .shaderRead]
        guard let rt = device.makeTexture(descriptor: td), let cb = queue.makeCommandBuffer() else { return nil }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = rt
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        guard encode(cb, rp, u) else { return nil }
        cb.commit()
        cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        rt.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return px
    }

    func loadPhoto(_ url: URL) {
        guard let ns = NSImage(contentsOf: url),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        let w = 1_024, h = max(1, Int(Double(cg.height) / Double(cg.width) * 1_024.0))
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let d = ctx.data else { return }
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: w, height: h, mipmapped: false
        )
        td.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: td) else { return }
        t.replace(
            region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
            withBytes: d, bytesPerRow: w * 4
        )
        photo = t
        Pref.d.set(true, forKey: "isPhoto")
    }

    func draw(in view: MTKView) {
        guard let rp = view.currentRenderPassDescriptor,
              let rt = view.currentDrawable,
              let cb = queue.makeCommandBuffer()
        else { return }
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let size = view.drawableSize
        guard encode(cb, rp, makeUniforms(w: Int(size.width), h: Int(size.height), time: now)) else { return }
        if probeFrames > 0 {
            probeFrames -= 1
            cb.present(rt)
            cb.commit()
            cb.waitUntilCompleted()
            let tex = rt.texture
            let w = tex.width, h = tex.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            tex.getBytes(
                &px, bytesPerRow: w * 4,
                from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0
            )
            let s = redStats(px)
            FileHandle.standardError.write(
                Data(
                    "live frame \(w)x\(h) min=\(s.lo) max=\(s.hi) mean=\(s.mean)\n".utf8))
            // probe mode has to end by itself: the app is a wallpaper daemon and
            // would otherwise never exit, so a shell capturing its output hangs
            if ProcessInfo.processInfo.environment["PIXELDISH_PROBE_EXIT"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            }
            return
        }
        cb.present(rt)
        cb.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

let kShaderPath = Bundle.main.path(forResource: "shader", ofType: "metallib") ?? "build/shader.metallib"
