import Metal

private struct WindParams {
    var controls: SIMD4<Float>
    var source: SIMD4<Float>
}

final class WakeDrawer {
    private let grid = MTLSize(width: 320, height: 144, depth: 1)
    private let device: MTLDevice
    private let wind: MTLComputePipelineState
    private let advect: MTLComputePipelineState
    private var states: [MTLTexture] = []
    private var tracers: [MTLTexture] = []
    private var front = 0, tracer = 0
    private var seed: Float?
    private var controls = SIMD4<Float>.zero
    private var clock: Float = 0
    private var remainder: Float = 0
    // The two-dimensional Courant limit includes both jet velocity components and sound speed.
    private let dt: Float = 0.1
    private var step: UInt32 = 0
    var plasma: MTLTexture? { states.isEmpty ? nil : states[front] }
    var filaments: MTLTexture? { tracers.isEmpty ? nil : tracers[tracer] }
    var time: Float { Float(step) * dt }

    init?(device: MTLDevice, library: MTLLibrary) {
        guard let fn = library.makeFunction(name: "wakeWind"),
              let pipeline = try? device.makeComputePipelineState(function: fn),
              let adv = library.makeFunction(name: "wakeFilaments"),
              let advection = try? device.makeComputePipelineState(function: adv)
        else { return nil }
        self.device = device
        wind = pipeline
        advect = advection
    }

    func clear() {
        guard !states.isEmpty else { return }
        states = []
        tracers = []
        seed = nil
    }

    private func allocate() -> Bool {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: grid.width, height: grid.height, mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = [.shaderRead, .shaderWrite]
        guard let a = device.makeTexture(descriptor: desc), let b = device.makeTexture(descriptor: desc)
        else { return false }
        desc.pixelFormat = .rg16Float
        desc.width *= 2
        desc.height *= 2
        guard let c = device.makeTexture(descriptor: desc), let d = device.makeTexture(descriptor: desc)
        else { return false }
        states = [a, b]
        tracers = [c, d]
        return true
    }

    func encode(_ cb: MTLCommandBuffer, _ u: Uniforms) {
        let t = u.misc.z, knobs = u.shp.0
        let reset = seed != u.misc.x || (t <= clock && knobs != controls)
        guard !states.isEmpty || allocate() else { return }
        let elapsed = reset ? 0 : remainder + min(max(t - clock, 0), 0.1) * (44 / dt)
        // Give the slowest wind enough time to reach the visible downstream boundary on a cold still.
        let steps = reset ? Int(288 / dt) : Int(elapsed)
        guard steps > 0 else {
            remainder = elapsed
            clock = t
            return
        }
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        let fine = MTLSize(width: grid.width * 2, height: grid.height * 2, depth: 1)
        let group = MTLSize(width: 16, height: 8, depth: 1)
        if reset { step = 0 }
        for i in 0 ..< steps {
            var params = WindParams(controls: knobs, source: SIMD4(u.misc.x, time, reset && i == 0 ? 1 : 0, dt))
            enc.setComputePipelineState(wind)
            enc.setBytes(&params, length: MemoryLayout<WindParams>.stride, index: 0)
            enc.setTexture(states[front], index: 0)
            enc.setTexture(states[1 - front], index: 1)
            enc.dispatchThreads(grid, threadsPerThreadgroup: group)
            front = 1 - front
            if step.isMultiple(of: 4) {
                enc.setComputePipelineState(advect)
                enc.setTexture(tracers[tracer], index: 0)
                enc.setTexture(tracers[1 - tracer], index: 1)
                enc.setTexture(states[front], index: 2)
                enc.dispatchThreads(fine, threadsPerThreadgroup: group)
                tracer = 1 - tracer
            }
            step &+= 1
        }
        enc.endEncoding()
        controls = knobs
        seed = u.misc.x
        clock = t
        remainder = reset ? 0 : elapsed - Float(steps)
    }
}
