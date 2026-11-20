import Metal

private struct WindSample {
    var coreMass: Float = 0
    var tailEjecta: Float = 0
}

// Read the conserved gas state before exposure and dithering. The core patch covers the
// sink for the fixed seed 2.1. The tail begins well beyond either jet nozzle.
private func windSample(_ r: DishRenderer) -> WindSample? {
    guard let gas = r.wake.plasma else { return nil }
    let bytesPerRow = gas.width * 8, bytes = bytesPerRow * gas.height
    guard let buf = r.device.makeBuffer(length: bytes, options: .storageModeShared),
          let cb = r.queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder()
    else { return nil }
    blit.copy(
        from: gas, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
        sourceSize: MTLSize(width: gas.width, height: gas.height, depth: 1),
        to: buf, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytes
    )
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    guard cb.status == .completed else { return nil }
    let cells = buf.contents().bindMemory(to: SIMD4<Float16>.self, capacity: gas.width * gas.height)
    let cx = Int(0.55 * Double(gas.width)), cy = Int(0.40 * Double(gas.height))
    var result = WindSample()
    for y in 0 ..< gas.height {
        for x in 0 ..< gas.width {
            let s = cells[y * gas.width + x]
            guard s.x.isFinite, s.x > 0, s.y.isFinite, s.z.isFinite, s.w >= 0, s.w <= s.x else { return nil }
            if abs(x - cx) <= 3, abs(y - cy) <= 3 { result.coreMass += Float(s.x) }
            if x > cx + 25 { result.tailEjecta += Float(s.w) }
        }
    }
    return result
}

func wakeChecks(_ r: DishRenderer) -> [(String, Bool)] {
    guard let shape = kShapeNames.firstIndex(of: "Wake") else { return [("wake registered", false)] }
    var u = comboUniforms(shape, 3, w: 160, h: 90)
    u.misc = SIMD4(2.1, 0, 0, 0.05)
    u.look.w = 2
    u.setPalette(kPalettes[0].1, colors: 2)
    func draw() -> [UInt8]? { r.render(u, w: 160, h: 90) }

    let first = draw()
    u.misc.z = 0.1
    let moved = draw()
    u.misc.z = 0
    let held = draw()
    u.misc.x += 1
    let reseeded = draw()
    u.misc.x = 2.1
    let repeatFrame = draw()
    u.shp.0.w = 1
    _ = draw()
    let jet = windSample(r)
    // Change only gravity between otherwise identical wind-only runs.
    u.shp.0.w = 0
    u.shp.0.z = 2
    _ = draw()
    let gravity = windSample(r)
    u.shp.0.z = 0
    _ = draw()
    let free = windSample(r)
    u.shp.0.w = 2
    _ = draw()
    return [
        ("the hypergiant fills the foreground", first.map { pixels in
            // At this framing the lower left looks into the photosphere, the upper middle into space.
            func lit(_ x: Int, _ y: Int) -> Int {
                (y ..< y + 24).reduce(0) { sum, row in
                    sum + (x ..< x + 24).filter { pixels[(row * 160 + $0) * 4] > 128 }.count
                }
            }
            return lit(4, 44) > lit(78, 4) + 160
        } ?? false),
        ("wake evolves and holds the live frame on pause", moved != nil && moved != first && held == moved),
        (
            "wake reseeds deterministically",
            first != nil && reseeded != nil && reseeded != first && repeatFrame == first
        ),
        (
            "strong gravity focuses passing gas into the accretion sink",
            (free?.coreMass ?? 0) > 0 && (gravity?.coreMass ?? 0) > 2 * (free?.coreMass ?? .infinity)
        ),
        ("wind carries protostellar ejecta downstream", (jet?.tailEjecta ?? 0) > 0 && gravity?.tailEjecta == 0),
        ("unbound jets retain positive density at maximum outflow", windSample(r) != nil)
    ]
}
