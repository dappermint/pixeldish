import Metal
import simd

struct ParticleUniforms {
    var viewProj = matrix_identity_float4x4
    var time: Float = 0, dt: Float = 0, gain: Float = 0, pointSize: Float = 0
    var shp0: SIMD4<Float> = .zero, shp1: SIMD4<Float> = .zero
    var shape: UInt32 = 0, frame: UInt32 = 0, steps: UInt32 = 0, reset: UInt32 = 0
}

let kParticleShapes = ["Protodisk", "Magnetar"].compactMap { kShapeNames.firstIndex(of: $0) }

// sim time runs at 0.6 units a second, so the disk's r = 1 orbit takes ~10 s at speed 1
final class ParticleDrawer {
    let device: MTLDevice
    let sim: MTLComputePipelineState
    let draw: MTLRenderPipelineState
    var particles: MTLBuffer?
    var density: MTLTexture?
    var key: [Float] = []
    var simT: Float = 0
    var frame: UInt32 = 0

    init?(dev: MTLDevice, lib: MTLLibrary) {
        guard let kf = lib.makeFunction(name: "particlesSim"),
              let s = try? dev.makeComputePipelineState(function: kf)
        else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "particlesVert")
        pd.fragmentFunction = lib.makeFunction(name: "particlesFrag")
        let ca: MTLRenderPipelineColorAttachmentDescriptor = pd.colorAttachments[0]
        ca.pixelFormat = .r16Float
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one
        ca.destinationRGBBlendFactor = .one
        guard let d = try? dev.makeRenderPipelineState(descriptor: pd) else { return nil }
        device = dev
        sim = s
        draw = d
    }

    func clear() {
        particles = nil
        density = nil
        key = []
    }

    // the count follows the pixel count, so the density slider costs the same on any display
    func encode(_ cb: MTLCommandBuffer, _ u: Uniforms) {
        let w = Int(u.view.x), h = Int(u.view.y)
        let isDisk = Int(u.look.x) == kParticleShapes.first
        let count = min(max(Int(Float(w * h) * u.shp.1.x), 4_096), 1 << 22)
        let t = u.misc.z * 0.6
        var pu = ParticleUniforms()
        pu.shp0 = u.shp.0
        pu.shp1 = u.shp.1
        pu.shape = isDisk ? 0 : 1
        pu.viewProj = Self.camera(u, aspect: Float(w) / Float(max(h, 1)), isDisk: isDisk)
        pu.gain = (isDisk ? 0.03 : 0.025) / u.shp.1.x
        pu.pointSize = Float(h) * 0.012

        // the other knobs act on the running sim, so dragging one reshapes it live
        let newKey = [u.look.x, u.misc.x, Float(count)]
        if newKey != key || t < simT || particles == nil {
            guard ensure(count: count, w: w, h: h) else { return }
            // ponytail: one cold dispatch integrates every particle up to t, ~0.2 s at 5K on an M5;
            // split it if older GPUs trip the watchdog
            let steps: Float = isDisk ? 500 : 300
            pu.dt = isDisk ? 0.045 : 0.01
            pu.steps = UInt32(steps)
            pu.time = t - steps * pu.dt
            pu.reset = 1
            dispatch(cb, &pu, count, seed: u.misc.x)
            key = newKey
            simT = t
        } else if t > simT {
            let n = min(Int(((t - simT) / 0.012).rounded(.up)), 6)
            pu.dt = min((t - simT) / Float(n), 0.02)
            pu.steps = UInt32(n)
            pu.time = simT
            dispatch(cb, &pu, count, seed: u.misc.x)
            simT = t
        }

        pu.time = t
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = density
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(draw)
        enc.setVertexBuffer(particles, offset: 0, index: 0)
        enc.setVertexBytes(&pu, length: MemoryLayout<ParticleUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        enc.endEncoding()
    }

    private func dispatch(_ cb: MTLCommandBuffer, _ pu: inout ParticleUniforms, _ count: Int, seed: Float) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        frame &+= 1
        pu.frame = frame &+ seed.bitPattern &* 2_654_435_761
        enc.setComputePipelineState(sim)
        enc.setBuffer(particles, offset: 0, index: 0)
        enc.setBytes(&pu, length: MemoryLayout<ParticleUniforms>.stride, index: 1)
        enc.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: sim.threadExecutionWidth * 4, height: 1, depth: 1)
        )
        enc.endEncoding()
    }

    private func ensure(count: Int, w: Int, h: Int) -> Bool {
        let bytes = count * MemoryLayout<SIMD4<Float>>.stride * 2
        if (particles?.length ?? 0) !=
            bytes { particles = device.makeBuffer(length: bytes, options: .storageModePrivate) }
        if density?.width != w || density?.height != h {
            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Float,
                width: w,
                height: h,
                mipmapped: false
            )
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = .private
            density = device.makeTexture(descriptor: td)
        }
        frame = 0
        return particles != nil && density != nil
    }

    // inclination is the tilt of the view off the disk's axis or the star's spin axis;
    // the seed picks the azimuth the camera sits at
    private static func camera(_ u: Uniforms, aspect: Float, isDisk: Bool) -> simd_float4x4 {
        let inc = u.shp.0.x * .pi / 180, yaw = (u.misc.x * 0.37).truncatingRemainder(dividingBy: 1) * 2 * .pi
        let dist: Float = 8
        let eye = dist * SIMD3(sin(inc) * sin(yaw), cos(inc), sin(inc) * cos(yaw))
        let f = normalize(-eye)
        let up: SIMD3<Float> = abs(f.y) > 0.999 ? [0, 0, 1] : [0, 1, 0]
        let s = normalize(cross(f, up)), v = cross(s, f)
        let view = simd_float4x4(columns: (
            SIMD4(s.x, v.x, -f.x, 0), SIMD4(s.y, v.y, -f.y, 0), SIMD4(s.z, v.z, -f.z, 0),
            SIMD4(-dot(s, eye), -dot(v, eye), dot(f, eye), 1)
        ))
        let fy = dist / (isDisk ? 2.6 : 1.3) * max(u.view.z, 0.01), fx = fy / max(aspect, 0.1)
        let proj = simd_float4x4(columns: (
            SIMD4(fx, 0, 0, 0), SIMD4(0, fy, 0, 0), SIMD4(0, 0, -0.01, -1), SIMD4(0, 0, 1, 0)
        ))
        return proj * view
    }
}
