import Foundation
import Metal
import simd

final class PipeDrawer {
    let device: MTLDevice
    let meshes: PipeMeshes
    let pipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    var depthTex: MTLTexture?
    var instBufs: [MTLBuffer?] = [nil, nil, nil]
    var ringIdx = 0
    var cachedScene: PipeScene?

    init?(dev: MTLDevice, lib: MTLLibrary) {
        guard let m = PipeMeshes(dev),
              let vf = lib.makeFunction(name: "pipesVert"),
              let ff = lib.makeFunction(name: "pipesFrag")
        else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vf
        pd.fragmentFunction = ff
        pd.colorAttachments[0].pixelFormat = .rg32Float
        pd.depthAttachmentPixelFormat = .depth32Float
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        guard let pso = try? dev.makeRenderPipelineState(descriptor: pd),
              let dss = dev.makeDepthStencilState(descriptor: dd)
        else { return nil }
        device = dev
        meshes = m
        pipeline = pso
        depthState = dss
    }

    func clear() {
        depthTex = nil
        cachedScene = nil
    }

    private func ensureDepth(w: Int, h: Int) -> MTLTexture? {
        if depthTex?.width != w || depthTex?.height != h {
            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float, width: w, height: h, mipmapped: false
            )
            td.usage = [.renderTarget]
            td.storageMode = .private
            depthTex = device.makeTexture(descriptor: td)
        }
        return depthTex
    }

    private func ensureBuffer(count: Int) -> MTLBuffer? {
        ringIdx = (ringIdx + 1) % instBufs.count
        let bytes = max(count, 512) * MemoryLayout<PipeInstance>.stride
        if (instBufs[ringIdx]?.length ?? 0) < bytes {
            instBufs[ringIdx] = device.makeBuffer(length: max(bytes, 1_536 * MemoryLayout<PipeInstance>.stride))
        }
        return instBufs[ringIdx]
    }

    private func sceneState(_ u: Uniforms, aspect: Float) -> (scene: PipeScene, cycle: Int, phase: Float) {
        let spd = Double(u.shp.0.w)
        let tReal = (u.misc.z == 0 || spd <= 0.001) ? 15.5 : Double(u.misc.z) * spd / 0.35
        let cycle = Int(floor(tReal / 20.0))
        let phase = Float(tReal - Double(cycle) * 20.0)
        let jointMode = u.shp.0.y < 0.5 ? 0 : (u.shp.0.y > 1.5 ? 2 : 1)
        let ar = max(aspect, 0.5)
        let nx = ar >= 1 ? max(11, min(23, Int((11.0 * ar).rounded()))) : 11
        let ny = ar >= 1 ? 11 : max(11, min(23, Int((11.0 / ar).rounded())))
        let key = [Int(u.misc.x.bitPattern), cycle, nx, ny, 15, jointMode]
        if let c = cachedScene, c.key == key { return (c, cycle, phase) }
        let s = PipeScene.simulate(seed: u.misc.x, cycle: cycle, aspect: aspect, jointMode: jointMode)
        cachedScene = s
        return (s, cycle, phase)
    }

    func encode(_ cb: MTLCommandBuffer, into target: MTLTexture, _ u: Uniforms) {
        let w = target.width, h = target.height
        guard let depth = ensureDepth(w: w, h: h) else { return }
        let aspect = Float(w) / Float(max(h, 1))
        let (scene, cycle, phase) = sceneState(u, aspect: aspect)
        let curTick = phase * max(Float(scene.totalTicks) / 17.2, 16.0)
        let r = min(max(u.shp.0.x / 0.16, 0.5), 1.85)
        let groups = Self.buildInstances(scene: scene, curTick: curTick, r: r)
        let all = groups.cyl + groups.sph + groups.elb + groups.tea

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        rp.depthAttachment.texture = depth
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.clearDepth = 1.0
        rp.depthAttachment.storeAction = .dontCare

        guard let buf = ensureBuffer(count: all.count),
              let enc = cb.makeRenderCommandEncoder(descriptor: rp)
        else { return }
        if !all.isEmpty {
            _ = all.withUnsafeBytes { raw in raw.baseAddress.map { memcpy(buf.contents(), $0, raw.count) } }
        }
        var uni = Self.makeUniforms(u: u, aspect: aspect, cycle: cycle, phase: phase)
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setFrontFacing(.counterClockwise)
        enc.setVertexBuffer(meshes.buffer, offset: 0, index: 0)
        enc.setVertexBuffer(buf, offset: 0, index: 1)
        enc.setVertexBytes(&uni, length: MemoryLayout<PipeUniforms>.stride, index: 2)
        enc.setFragmentBytes(&uni, length: MemoryLayout<PipeUniforms>.stride, index: 0)

        var base = 0
        for (range, count, cull) in [
            (meshes.cyl, groups.cyl.count, MTLCullMode.back),
            (meshes.sph, groups.sph.count, .back),
            (meshes.elb, groups.elb.count, .back),
            (meshes.tea, groups.tea.count, .none)
        ] where count > 0 {
            enc.setCullMode(cull)
            enc.drawPrimitives(
                type: .triangle, vertexStart: range.lowerBound, vertexCount: range.count,
                instanceCount: count, baseInstance: base
            )
            base += count
        }
        enc.endEncoding()
    }

    private static func makeUniforms(u: Uniforms, aspect: Float, cycle: Int, phase: Float) -> PipeUniforms {
        // Win98 VIEW.CXX: stationary camera at z = -75, 90-deg vertical FOV, +9.73156 deg Y-turn per reset
        let seedOff = u.misc.x == 0 ? 0 : (u.misc.x * 0.37).truncatingRemainder(dividingBy: 1.0) * 2 * .pi
        let yRot = (Float(cycle) * 9.73156 * (.pi / 180.0)) + seedOff
        let cy = cos(yRot), sy = sin(yRot)
        let zTrans = -75.0 / max(u.shp.0.z, 0.5)
        let view = simd_float4x4(columns: (
            SIMD4(cy, 0, -sy, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(sy, 0, cy, 0),
            SIMD4(0, 0, zTrans, 1)
        ))
        let fy = max(u.view.z, 0.1), fx = fy / max(aspect, 0.1)
        let zNear: Float = 1.0, zFar: Float = 300.0, qz = zFar / (zNear - zFar)
        let proj = simd_float4x4(columns: (
            SIMD4(fx, 0, 0, 0),
            SIMD4(0, fy, 0, 0),
            SIMD4(0, 0, qz, -1),
            SIMD4(0, 0, zNear * qz, 0)
        ))
        let dissolve = max(0, (phase - 18.6) / 1.4)
        let block = max(floor(min(u.view.x, u.view.y) / 32.0), 1.0)
        let cSeed = Float(cycle % 997) * 1.37 + fractFloat(u.misc.x) * 19.0
        return PipeUniforms(view: view, proj: proj, params: SIMD4(u.shp.1.x, dissolve, block, cSeed))
    }

    private static func fractFloat(_ x: Float) -> Float { x - floor(x) }

    private static func sphereInst(pos: SIMD3<Float>, r: Float, mat: Float) -> PipeInstance {
        PipeInstance(c0: SIMD4(r, 0, 0, mat), c1: SIMD4(0, r, 0, 0), c2: SIMD4(0, 0, r, 0), c3: SIMD4(pos, 1))
    }

    private static func buildInstances(
        scene: PipeScene, curTick: Float, r: Float
    ) -> (cyl: [PipeInstance], sph: [PipeInstance], elb: [PipeInstance], tea: [PipeInstance]) {
        var cyl: [PipeInstance] = [], sph: [PipeInstance] = [], elb: [PipeInstance] = [], tea: [PipeInstance] = []
        let n = scene.prims.count
        cyl.reserveCapacity(n)
        sph.reserveCapacity(n / 2 + 8)
        elb.reserveCapacity(n / 2)
        let rCap = 1.41421356 * r, rBall = 1.4264053 * r
        for p in scene.prims where p.tick <= curTick {
            let mf = Float(p.mat) + 1
            switch p.kind {
            case .cap:
                sph.append(sphereInst(pos: p.pos, r: rCap, mat: mf))
            case .ball:
                sph.append(sphereInst(pos: p.pos, r: rBall, mat: mf))
            case let .tea(yaw):
                let c = cos(yaw) * r, s = sin(yaw) * r
                tea.append(PipeInstance(
                    c0: SIMD4(c, 0, -s, mf), c1: SIMD4(0, r, 0, 1), c2: SIMD4(s, 0, c, 0), c3: SIMD4(p.pos, 1)
                ))
            case let .elb(dIn, dOut):
                let di = kPipeDirs[dIn], doV = kPipeDirs[dOut]
                let u = -r * doV, v = r * di, w = r * simd_cross(-doV, di)
                elb.append(PipeInstance(
                    c0: SIMD4(u, mf), c1: SIMD4(v, 0), c2: SIMD4(w, 0), c3: SIMD4(p.pos - r * di + r * doV, 1)
                ))
            case let .cyl(dir, isLong):
                let d = kPipeDirs[dir]
                let start = isLong ? (p.pos - r * d) : (p.pos + r * d)
                let frac = min(curTick - p.tick, 1.0)
                let len = (isLong ? 7.0 : (7.0 - 2.0 * r)) * frac
                if len > 1e-3 {
                    cyl.append(PipeInstance(
                        c0: SIMD4(kCylU[dir] * r, mf), c1: SIMD4(kCylV[dir] * r, 0),
                        c2: SIMD4(d * len, 0), c3: SIMD4(start, 1)
                    ))
                    if frac < 1.0 { sph.append(sphereInst(pos: start + d * len, r: r, mat: mf)) }
                }
            }
        }
        return (cyl, sph, elb, tea)
    }
}
