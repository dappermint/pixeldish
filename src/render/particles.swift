import Metal
import simd

struct ParticleUniforms {
    var viewProj = matrix_identity_float4x4
    var eye: SIMD4<Float> = .zero
    var time: Float = 0, dt: Float = 0, gain: Float = 0, deposit: Float = 0
    var seed: Float = 0
    var shp0: SIMD4<Float> = .zero, shp1: SIMD4<Float> = .zero
    var shape: UInt32 = 0, frame: UInt32 = 0, steps: UInt32 = 0, reset: UInt32 = 0
}

let kParticleShapes = ["Protodisk", "Magnetar"].compactMap { kShapeNames.firstIndex(of: $0) }

// sim time runs at 0.6 units a second, so the disk's r = 1 orbit takes ~10 s at speed 1
final class ParticleDrawer {
    let device: MTLDevice
    let sim: MTLComputePipelineState, simDisk: MTLComputePipelineState, simBodies: MTLComputePipelineState
    let draw: MTLRenderPipelineState, deposit: MTLRenderPipelineState, fieldPass: MTLRenderPipelineState
    let gridFormat: MTLPixelFormat
    var particles: MTLBuffer?
    var density: MTLTexture?
    // the disk's grid: gas count and momentum per cell, the positions summed per cell, and the
    // gravity and pressure the grains read back
    var grid: MTLTexture?
    var moment: MTLTexture?
    var field: MTLTexture?
    var press: MTLTexture?
    // three planets, 32 bytes each: position, velocity, home radius, share of the mass knob
    var bodies: MTLBuffer?
    // steps a cold disk runs before its first frame, so a still or an export is not a
    // featureless disk; it keeps forming live after that
    var warm = 200
    var key: [Float] = []
    var simT: Float = 0
    var frame: UInt32 = 0
    // screen pixels per world unit at the origin, where fmain draws the star
    var pxPerUnit: Float = 0

    init?(dev: MTLDevice, lib: MTLLibrary) {
        guard let kf = lib.makeFunction(name: "particlesSim"),
              let s = try? dev.makeComputePipelineState(function: kf),
              let df = lib.makeFunction(name: "diskSim"),
              let sd = try? dev.makeComputePipelineState(function: df),
              let bf = lib.makeFunction(name: "diskBodies"),
              let sb = try? dev.makeComputePipelineState(function: bf)
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
        // half floats stop counting at 2048 grains a cell, so they are only the fallback
        gridFormat = dev.supports32BitFloatFiltering ? .rgba32Float : .rgba16Float
        pd.vertexFunction = lib.makeFunction(name: "diskDepositVert")
        pd.fragmentFunction = lib.makeFunction(name: "diskDepositFrag")
        let cb: MTLRenderPipelineColorAttachmentDescriptor = pd.colorAttachments[1]
        for c in [ca, cb] {
            c.pixelFormat = gridFormat
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one
            c.destinationRGBBlendFactor = .one
        }
        guard let dep = try? dev.makeRenderPipelineState(descriptor: pd) else { return nil }
        pd.vertexFunction = lib.makeFunction(name: "vmain")
        pd.fragmentFunction = lib.makeFunction(name: "diskField")
        for c in [ca, cb] {
            c.pixelFormat = .rgba16Float
            c.isBlendingEnabled = false
        }
        guard let fp = try? dev.makeRenderPipelineState(descriptor: pd) else { return nil }
        device = dev
        sim = s
        simDisk = sd
        simBodies = sb
        draw = d
        deposit = dep
        fieldPass = fp
    }

    func clear() {
        particles = nil
        density = nil
        grid = nil
        moment = nil
        field = nil
        press = nil
        bodies = nil
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
        let cam = Self.camera(u, aspect: Float(w) / Float(max(h, 1)), isDisk: isDisk)
        pu.viewProj = cam.viewProj
        pu.eye = SIMD4(cam.eye, 0)
        pxPerUnit = cam.unit * Float(h) / 2
        // sprites keep their size in pixels and every particle deposits the same total,
        // so the exposure and the grain per pixel are the same on any display
        pu.gain = (isDisk ? 0.6 : 0.45) / u.shp.1.x
        pu.deposit = 1 / (Float(count) * (1 - u.shp.1.y))
        pu.seed = u.misc.x

        // the other knobs act on the running sim, so dragging one reshapes it live
        let newKey = [u.look.x, u.misc.x, Float(count)]
        if newKey != key || t < simT || particles == nil {
            guard ensure(count: count, w: w, h: h, isDisk: isDisk) else { return }
            pu.reset = 1
            if isDisk {
                coldDisk(cb, &pu, count, seed: u.misc.x)
            } else {
                pu.dt = 0.01
                pu.steps = 300
                pu.time = t - 3
                dispatch(cb, &pu, count, seed: u.misc.x)
            }
            key = newKey
            simT = t
        } else if t > simT {
            let n = min(Int(((t - simT) / 0.012).rounded(.up)), 6)
            pu.dt = min((t - simT) / Float(n), 0.02)
            if isDisk {
                for _ in 0 ..< n {
                    diskStep(cb, &pu, count, seed: u.misc.x)
                }
            } else {
                pu.steps = UInt32(n)
                pu.time = simT
                dispatch(cb, &pu, count, seed: u.misc.x)
            }
            simT = t
        }

        pu.time = t
        splat(cb, &pu, count)
    }

    private func splat(_ cb: MTLCommandBuffer, _ pu: inout ParticleUniforms, _ count: Int) {
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
        if let d = density, let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: d)
            blit.endEncoding()
        }
    }

    private func dispatch(_ cb: MTLCommandBuffer, _ pu: inout ParticleUniforms, _ count: Int, seed: Float) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        frame &+= 1
        pu.frame = frame &+ seed.bitPattern &* 2_654_435_761
        enc.setComputePipelineState(pu.shape == 0 ? simDisk : sim)
        enc.setTexture(field, index: 0)
        enc.setTexture(press, index: 1)
        enc.setBuffer(particles, offset: 0, index: 0)
        enc.setBuffer(bodies, offset: 0, index: 2)
        enc.setBytes(&pu, length: MemoryLayout<ParticleUniforms>.stride, index: 1)
        enc.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: sim.threadExecutionWidth * 4, height: 1, depth: 1)
        )
        enc.endEncoding()
    }

    func ensure(count: Int, w: Int, h: Int, isDisk: Bool) -> Bool {
        let bytes = count * MemoryLayout<SIMD4<Float>>.stride * 2
        if (particles?.length ?? 0) !=
            bytes { particles = device.makeBuffer(length: bytes, options: .storageModePrivate) }
        if density?.width != w || density?.height != h {
            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Float,
                width: w,
                height: h,
                mipmapped: true
            )
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = .private
            density = device.makeTexture(descriptor: td)
        }
        if isDisk, grid == nil {
            let gd = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: gridFormat, width: 256, height: 256, mipmapped: true
            )
            gd.usage = [.renderTarget, .shaderRead]
            grid = device.makeTexture(descriptor: gd)
            moment = device.makeTexture(descriptor: gd)
            gd.pixelFormat = .rgba16Float
            gd.mipmapLevelCount = 1
            field = device.makeTexture(descriptor: gd)
            press = device.makeTexture(descriptor: gd)
            bodies = device.makeBuffer(length: 96, options: .storageModeShared)
        }
        frame = 0
        return particles != nil && density != nil && (!isDisk || (press != nil && bodies != nil))
    }

    // inclination is the tilt of the view off the disk's axis or the star's spin axis;
    // the seed picks the azimuth the camera sits at
    private static func camera(
        _ u: Uniforms, aspect: Float, isDisk: Bool
    ) -> (viewProj: simd_float4x4, eye: SIMD3<Float>, unit: Float) {
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
        return (proj * view, eye, fy / dist)
    }
}

extension ParticleDrawer {
    // scatter the grains, build the field once so they can start on circular orbits, then
    // run the warm-up.
    // ponytail: every step is four passes, so the cold start grows with `warm`; spread it
    // over a few frames if it ever shows as a hitch
    private func coldDisk(_ cb: MTLCommandBuffer, _ pu: inout ParticleUniforms, _ count: Int, seed: Float) {
        moveBodies(cb, &pu)
        dispatch(cb, &pu, count, seed: seed)
        fieldPasses(cb, &pu, count)
        pu.reset = 2
        dispatch(cb, &pu, count, seed: seed)
        pu.reset = 0
        pu.dt = 0.015
        for _ in 0 ..< warm {
            diskStep(cb, &pu, count, seed: seed)
        }
    }

    // one step of the disk: the gas deposits on the grid, the grid turns into the field, then
    // the grains and the planets move in it. the grains go first so both see the other where
    // it was at the start of the step: grains chasing a planet that has already moved pile up
    // ahead of it and tow it outward
    private func diskStep(_ cb: MTLCommandBuffer, _ pu: inout ParticleUniforms, _ count: Int, seed: Float) {
        fieldPasses(cb, &pu, count)
        dispatch(cb, &pu, count, seed: seed)
        moveBodies(cb, &pu)
    }

    func moveBodies(_ cb: MTLCommandBuffer, _ pu: inout ParticleUniforms) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(simBodies)
        enc.setBuffer(bodies, offset: 0, index: 0)
        enc.setBytes(&pu, length: MemoryLayout<ParticleUniforms>.stride, index: 1)
        enc.setTexture(grid, index: 0)
        enc.setTexture(moment, index: 1)
        enc.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
        )
        enc.endEncoding()
    }

    func fieldPasses(_ cb: MTLCommandBuffer, _ pu: inout ParticleUniforms, _ count: Int) {
        guard let grid, let moment, let field, let press else { return }
        let rp = MTLRenderPassDescriptor()
        for (i, tex) in [grid, moment].enumerated() {
            rp.colorAttachments[i].texture = tex
            rp.colorAttachments[i].loadAction = .clear
            rp.colorAttachments[i].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rp.colorAttachments[i].storeAction = .store
        }
        guard let dep = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        dep.setRenderPipelineState(deposit)
        dep.setVertexBuffer(particles, offset: 0, index: 0)
        dep.setVertexBytes(&pu, length: MemoryLayout<ParticleUniforms>.stride, index: 1)
        dep.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        dep.endEncoding()
        if let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: grid)
            blit.generateMipmaps(for: moment)
            blit.endEncoding()
        }
        for (i, tex) in [field, press].enumerated() {
            rp.colorAttachments[i].texture = tex
            rp.colorAttachments[i].loadAction = .dontCare
        }
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(fieldPass)
        enc.setFragmentBytes(&pu, length: MemoryLayout<ParticleUniforms>.stride, index: 0)
        enc.setFragmentTexture(grid, index: 0)
        enc.setFragmentTexture(moment, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}
