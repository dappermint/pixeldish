import AppKit
import ImageIO
import Metal
import MetalKit
import UniformTypeIdentifiers

let kShapeNames = [
    "Drift", "Shepard", "Sines", "Fringe", "Curtain", "Voronoi",
    "Contour", "Vortex", "Sweep", "Glitch", "Twill", "Belts", "Circuit",
    "Julia", "Kali"
]
let kDitherNames = [
    "Smooth", "Poster", "Bayer 4", "Bayer 8", "Noise",
    "Halftone", "Lines", "Diamond", "ASCII", "Benday",
    "Bayer 2", "Bayer 16", "R2"
]

struct Uniforms {
    var look: SIMD4<Float> = .zero
    var tune: SIMD4<Float> = .zero
    var misc: SIMD4<Float> = .zero
    var view: SIMD4<Float> = .zero
    var pal: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
        (.zero, .zero, .zero, .zero, .zero)
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
    var atlas: MTLTexture?
    var photo: MTLTexture?
    var start = Date()
    var paused = false
    // PIXELDISH_PROBE reads the live drawable back for a few frames; used by
    // `just test-live` to prove the window path draws, since the display itself
    // cannot be screenshotted without screen-recording permission
    var probeFrames = 0

    init?(shader path: String) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue()
        else { return nil }
        device = dev
        queue = q
        let src = try? String(contentsOfFile: path, encoding: .utf8)
        guard let src, let lib = try? dev.makeLibrary(source: src, options: nil),
              let vf = lib.makeFunction(name: "vmain"),
              let ff = lib.makeFunction(name: "fmain")
        else {
            FileHandle.standardError.write(Data("pixeldish: shader compile failed\n".utf8))
            return nil
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vf
        pd.fragmentFunction = ff
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        guard let p = try? dev.makeRenderPipelineState(descriptor: pd) else { return nil }
        pipeline = p
        super.init()
        atlas = makeRampAtlas(dev)
    }

    func encode(_ enc: MTLRenderCommandEncoder, _ u: Uniforms) {
        var u = u
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(photo, index: 0)
        enc.setFragmentTexture(atlas, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
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
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        encode(enc, u)
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
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rp)
        else { return }
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let t = paused ? 0 : Float(Date().timeIntervalSince(start)) * prefValue("speed")
        let size = view.drawableSize
        encode(enc, makeUniforms(w: Int(size.width), h: Int(size.height), time: t))
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

let kShaderPath = Bundle.main.path(forResource: "shader", ofType: "metal") ?? "src/render/shader.metal"
