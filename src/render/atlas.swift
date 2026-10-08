import Metal

// Rendered text only reaches ~0.35 ink coverage even at 16px heavy (measured),
// so glyphs cannot express a shade range. Instead one fixed rank order over the
// cell's 64 pixels is inked from the front: cell i gets exactly i/15 coverage,
// which is an exact, monotonic ramp at any size.
let kAsciiRamp = Array(" .,:;-~=+*xoawm#@")

func makeRampAtlas(_ dev: MTLDevice) -> MTLTexture? {
    let n = kAsciiRamp.count, s = 8
    var px = [UInt8](repeating: 0, count: n * s * s)

    var order = Array(0 ..< (s * s))
    var seed: UInt32 = 0x9E37_79B9
    for i in stride(from: order.count - 1, through: 1, by: -1) {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        order.swapAt(i, Int(seed >> 16) % (i + 1))
    }
    for i in 0 ..< n {
        let ink = Int((Double(i) / Double(n - 1) * Double(s * s)).rounded())
        for (rank, ci) in order.enumerated() {
            let x = ci % s, y = ci / s
            px[y * n * s + i * s + x] = rank < ink ? 255 : 0
        }
    }
    let td = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r8Unorm,
        width: n * s, height: s, mipmapped: false
    )
    guard let t = dev.makeTexture(descriptor: td) else { return nil }
    t.replace(
        region: MTLRegionMake2D(0, 0, n * s, s), mipmapLevel: 0,
        withBytes: px, bytesPerRow: n * s
    )
    return t
}
