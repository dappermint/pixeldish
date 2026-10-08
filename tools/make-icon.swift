import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Draws the app icon: a Bayer-dithered gradient square with the same
// palette the app ships, so the icon is made by the thing it represents.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.iconset"
let pal: [SIMD3<Double>] = [
    SIMD3(0.05, 0.06, 0.12), SIMD3(0.20, 0.16, 0.38), SIMD3(0.55, 0.30, 0.52),
    SIMD3(0.90, 0.55, 0.45), SIMD3(0.98, 0.93, 0.86),
]

let bayer8: [[Double]] = [
    [0, 32, 8, 40, 2, 34, 10, 42],
    [48, 16, 56, 24, 50, 18, 58, 26],
    [12, 44, 4, 36, 14, 46, 6, 38],
    [60, 28, 52, 20, 62, 30, 54, 22],
    [3, 35, 11, 43, 1, 33, 9, 41],
    [51, 19, 59, 27, 49, 17, 57, 25],
    [15, 47, 7, 39, 13, 45, 5, 37],
    [63, 31, 55, 23, 61, 29, 53, 21],
]

func makeIcon(_ px: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8,
        bytesPerRow: px * 4, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // rounded-rect mask, macOS style
    let r = Double(px) * 0.2237
    let path = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: px, height: px),
        cornerWidth: r, cornerHeight: r, transform: nil
    )
    ctx.addPath(path)
    ctx.clip()
    ctx.setFillColor(CGColor(red: pal[0].x, green: pal[0].y, blue: pal[0].z, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))

    // a flow-ish field, then Bayer 8. The cell and the noise frequency both
    // scale with the canvas: at 16px a 1px dither is just mush, so small sizes
    // get a coarser cell and a smoother field to stay readable
    let cell = max(2, px / 48)
    let freq = px <= 64 ? 1.6 : 3.0
    let levels = 5.0
    for y in stride(from: 0, to: px, by: cell) {
        for x in stride(from: 0, to: px, by: cell) {
            let u = Double(x) / Double(px), v = Double(y) / Double(px)
            var field = 0.0
            var amp = 0.5, fx = u * freq, fy = v * freq
            for _ in 0 ..< 5 {
                let ii = floor(fx), jj = floor(fy)
                let fxx = fx - ii, fyy = fy - jj
                let ux = fxx * fxx * (3 - 2 * fxx), uy = fyy * fyy * (3 - 2 * fyy)
                func h(_ a: Double, _ b: Double) -> Double {
                    var px1 = (a * 123.34).truncatingRemainder(dividingBy: 1)
                    var py1 = (b * 456.21).truncatingRemainder(dividingBy: 1)
                    px1 = (px1 + 1).truncatingRemainder(dividingBy: 1)
                    py1 = (py1 + 1).truncatingRemainder(dividingBy: 1)
                    let d = px1 * (px1 + 45.32) + py1 * (py1 + 45.32)
                    return (px1 * (py1 + d)).truncatingRemainder(dividingBy: 1)
                }
                let n =
                    (h(ii, jj) * (1 - ux) + h(ii + 1, jj) * ux) * (1 - uy)
                        + (h(ii, jj + 1) * (1 - ux) + h(ii + 1, jj + 1) * ux) * uy
                field += n * amp
                let nfx = fx * 1.6 - fy * 1.2, nfy = fx * 1.2 + fy * 1.6
                fx = nfx
                fy = nfy
                amp *= 0.5
            }
            field = min(max(field, 0), 1)
            let bx = (x / cell) % 8, by = (y / cell) % 8
            let phi = (bayer8[by][bx] + 0.5) / 64.0
            let q = min(floor(phi + (levels - 1) * field), levels - 1) / (levels - 1)
            let f = q * (levels - 1)
            let i0 = min(max(Int(f), 0), 3)
            let t = f - Double(i0)
            let c = pal[i0] * (1 - t) + pal[i0 + 1] * t
            ctx.setFillColor(CGColor(red: c.x, green: c.y, blue: c.z, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
        }
    }
    return ctx.makeImage()!
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1_024),
]
for (name, px) in sizes {
    let img = makeIcon(px)
    let url = URL(fileURLWithPath: "\(outDir)/\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { print("failed \(name)")
        exit(1)
    }
}

print("wrote \(sizes.count) icon sizes to \(outDir)")
