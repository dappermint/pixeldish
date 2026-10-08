import CoreGraphics
import Foundation
import simd

// var, not let: PhotoPalette appends one generated "Photo" entry at runtime.
var kPalettes: [(String, [SIMD3<Float>])] = [
    (
        "Ember",
        [
            SIMD3(0.08, 0.04, 0.06), SIMD3(0.35, 0.09, 0.10),
            SIMD3(0.85, 0.30, 0.13), SIMD3(0.97, 0.71, 0.30), SIMD3(1.00, 0.96, 0.87)
        ]
    ),
    (
        "Dusk",
        [
            SIMD3(0.05, 0.06, 0.12), SIMD3(0.20, 0.16, 0.38),
            SIMD3(0.55, 0.30, 0.52), SIMD3(0.90, 0.55, 0.45), SIMD3(0.98, 0.93, 0.86)
        ]
    ),
    (
        "Mono",
        [
            SIMD3(0.04, 0.04, 0.05), SIMD3(0.25, 0.25, 0.27),
            SIMD3(0.50, 0.50, 0.52), SIMD3(0.76, 0.76, 0.78), SIMD3(0.98, 0.98, 0.97)
        ]
    ),
    (
        "Rust",
        [
            SIMD3(0.07, 0.05, 0.04), SIMD3(0.28, 0.13, 0.08),
            SIMD3(0.62, 0.32, 0.16), SIMD3(0.87, 0.62, 0.36), SIMD3(0.97, 0.91, 0.80)
        ]
    ),
    (
        "Moss",
        [
            SIMD3(0.04, 0.07, 0.05), SIMD3(0.13, 0.28, 0.18),
            SIMD3(0.34, 0.53, 0.28), SIMD3(0.72, 0.79, 0.48), SIMD3(0.95, 0.97, 0.88)
        ]
    ),
    (
        "Iris",
        [
            SIMD3(0.04, 0.04, 0.10), SIMD3(0.16, 0.13, 0.42),
            SIMD3(0.38, 0.32, 0.80), SIMD3(0.68, 0.62, 0.95), SIMD3(0.95, 0.94, 1.00)
        ]
    ),
    (
        "Candy",
        [
            SIMD3(0.10, 0.03, 0.10), SIMD3(0.55, 0.12, 0.45),
            SIMD3(0.95, 0.35, 0.60), SIMD3(0.99, 0.72, 0.45), SIMD3(1.00, 0.97, 0.92)
        ]
    ),
    (
        "Void",
        [
            SIMD3(0.03, 0.03, 0.05), SIMD3(0.18, 0.26, 0.44),
            SIMD3(0.36, 0.52, 0.74), SIMD3(0.62, 0.78, 0.90), SIMD3(0.92, 0.95, 0.98)
        ]
    ),
    (
        "Sand",
        [
            SIMD3(0.12, 0.09, 0.06), SIMD3(0.38, 0.29, 0.19),
            SIMD3(0.70, 0.58, 0.40), SIMD3(0.90, 0.82, 0.66), SIMD3(0.99, 0.96, 0.90)
        ]
    ),
    (
        "Neon",
        [
            SIMD3(0.01, 0.02, 0.10), SIMD3(0.24, 0.04, 0.52),
            SIMD3(0.88, 0.14, 0.88), SIMD3(0.88, 0.60, 0.72), SIMD3(0.98, 0.96, 0.96)
        ]
    ),
    (
        "Ink",
        [
            SIMD3(0.02, 0.03, 0.07), SIMD3(0.10, 0.18, 0.35),
            SIMD3(0.30, 0.45, 0.68), SIMD3(0.65, 0.78, 0.90), SIMD3(0.97, 0.98, 1.00)
        ]
    ),
    (
        "Amber",
        [
            SIMD3(0.08, 0.05, 0.02), SIMD3(0.35, 0.20, 0.03),
            SIMD3(0.78, 0.48, 0.06), SIMD3(0.96, 0.78, 0.30), SIMD3(1.00, 0.97, 0.88)
        ]
    ),
    // editor themes: official hexes, ordered dark to light so the ramp stays monotonic
    // Dracula Pro: background, selection, comment, purple, foreground
    (
        "Dracula",
        [
            SIMD3(0.133, 0.129, 0.173), SIMD3(0.271, 0.255, 0.345),
            SIMD3(0.475, 0.439, 0.663), SIMD3(0.584, 0.502, 1.000), SIMD3(0.973, 0.973, 0.949)
        ]
    ),
    // Dracula Pro Van Helsing: background, selection, comment, cyan, foreground
    (
        "Van Helsing",
        [
            SIMD3(0.043, 0.051, 0.059), SIMD3(0.255, 0.302, 0.345),
            SIMD3(0.439, 0.549, 0.663), SIMD3(0.502, 1.000, 0.918), SIMD3(0.973, 0.973, 0.949)
        ]
    ),
    // Catppuccin Mocha: base, surface1, overlay1, mauve, rosewater
    (
        "Mocha",
        [
            SIMD3(0.118, 0.118, 0.180), SIMD3(0.271, 0.278, 0.353),
            SIMD3(0.498, 0.518, 0.612), SIMD3(0.796, 0.651, 0.969), SIMD3(0.961, 0.878, 0.863)
        ]
    ),
    // Catppuccin Latte: text, overlay2, surface2, crust, base
    (
        "Latte",
        [
            SIMD3(0.298, 0.310, 0.412), SIMD3(0.486, 0.498, 0.576),
            SIMD3(0.675, 0.690, 0.745), SIMD3(0.863, 0.878, 0.910), SIMD3(0.937, 0.945, 0.961)
        ]
    ),
    // Nord: nord0, nord2, nord10, nord8, nord6
    (
        "Nord",
        [
            SIMD3(0.180, 0.204, 0.251), SIMD3(0.263, 0.298, 0.369),
            SIMD3(0.369, 0.506, 0.675), SIMD3(0.533, 0.753, 0.816), SIMD3(0.925, 0.937, 0.957)
        ]
    ),
    // Gruvbox dark: bg, bg2, orange, bright yellow, fg0
    (
        "Gruvbox",
        [
            SIMD3(0.157, 0.157, 0.157), SIMD3(0.314, 0.286, 0.271),
            SIMD3(0.839, 0.365, 0.055), SIMD3(0.980, 0.741, 0.184), SIMD3(0.984, 0.945, 0.780)
        ]
    ),
    // Tokyo Night: bg, fg_gutter, blue, fg_dark, fg
    (
        "Tokyo",
        [
            SIMD3(0.102, 0.106, 0.149), SIMD3(0.231, 0.259, 0.380),
            SIMD3(0.478, 0.635, 0.969), SIMD3(0.663, 0.694, 0.839), SIMD3(0.753, 0.792, 0.961)
        ]
    ),
    // Rose Pine: base, highlight high, dawn iris, iris, text
    (
        "Rose Pine",
        [
            SIMD3(0.098, 0.090, 0.141), SIMD3(0.251, 0.239, 0.322),
            SIMD3(0.565, 0.478, 0.663), SIMD3(0.769, 0.655, 0.906), SIMD3(0.878, 0.871, 0.957)
        ]
    )
]

// Builds a 5-stop palette from a photo: sort every pixel by luminance and
// average 5 equal-size buckets. Monotonic by construction (bucket i is all
// darker pixels than bucket i+1), no k-means or seed needed.
enum PhotoPalette {
    static func generate(from cg: CGImage) -> [SIMD3<Float>]? {
        let w = 64, h = 64
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var pixels: [(lum: Float, rgb: SIMD3<Float>)] = []
        pixels.reserveCapacity(w * h)
        for i in 0 ..< (w * h) {
            let r = Float(px[i * 4]) / 255, g = Float(px[i * 4 + 1]) / 255, b = Float(px[i * 4 + 2]) / 255
            pixels.append((0.2126 * r + 0.7152 * g + 0.0722 * b, SIMD3(r, g, b)))
        }
        pixels.sort { $0.lum < $1.lum }
        let bucket = pixels.count / 5
        return (0 ..< 5).map { i in
            let slice = pixels[(i * bucket) ..< (i == 4 ? pixels.count : (i + 1) * bucket)]
            let sum = slice.reduce(SIMD3<Float>(0, 0, 0)) { $0 + $1.rgb }
            return sum / Float(slice.count)
        }
    }

    // one custom slot, persisted flat in UserDefaults; ponytail: a palette
    // library with named/multiple slots would need real storage and UI, add
    // if one slot stops being enough
    static func save(_ pal: [SIMD3<Float>]) {
        d.set(pal.flatMap { [Double($0.x), Double($0.y), Double($0.z)] }, forKey: "customPalette")
        apply()
    }

    static let d = UserDefaults.standard

    static func apply() {
        guard let flat = d.array(forKey: "customPalette") as? [Double], flat.count == 15 else { return }
        var pal = [SIMD3<Float>]()
        for i in 0 ..< 5 {
            let r = Float(flat[i * 3]), g = Float(flat[i * 3 + 1]), b = Float(flat[i * 3 + 2])
            pal.append(SIMD3(r, g, b))
        }
        if kPalettes.last?.0 == "Photo" {
            kPalettes[kPalettes.count - 1] = ("Photo", pal)
        } else {
            kPalettes.append(("Photo", pal))
        }
    }
}
