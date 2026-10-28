import Foundation
import simd

// SGI GLAUX teapot.c / teapot.h (Copyright 1993 Silicon Graphics, Inc.,
// unrestricted permission to use, copy, modify, and distribute without fee).
// Scaled by 1.25 and rotated upright (+Y up) to match Win98 auxSolidTeapot(2.5 * r).
enum UtahTeapot {
    static func append(
        to out: inout [PipeVertex],
        grid: Int,
        addTri: (inout [PipeVertex], PipeVertex, PipeVertex, PipeVertex) -> Void
    ) {
        let cps = points
        let patches = patchIndices
        guard cps.count == 127, patches.count == 10 else { return }
        for (idx, patch) in patches.enumerated() {
            let sym: [(Float, Float, Bool)] = idx < 6
                ? [(1, 1, false), (1, -1, true), (-1, 1, true), (-1, -1, false)]
                : [(1, 1, false), (1, -1, true)]
            for (sx, sy, rev) in sym {
                var ctrl = [SIMD3<Float>](repeating: .zero, count: 16)
                for j in 0 ..< 4 {
                    for k in 0 ..< 4 {
                        let c = cps[patch[j * 4 + (rev ? (3 - k) : k)]]
                        ctrl[j * 4 + k] = SIMD3(1.25 * c.x * sx, 1.25 * (c.z - 1.5), -1.25 * c.y * sy)
                    }
                }
                tessellate(&out, ctrl: ctrl, grid: grid, addTri: addTri)
            }
        }
    }

    private static func basis(_ t: Float) -> (SIMD4<Float>, SIMD4<Float>) {
        let m = 1 - t
        return (
            SIMD4(m * m * m, 3 * t * m * m, 3 * t * t * m, t * t * t),
            SIMD4(-3 * m * m, 3 * m * (1 - 3 * t), 3 * t * (2 - 3 * t), 3 * t * t)
        )
    }

    private static func eval(_ c: [SIMD3<Float>], _ u: Float, _ v: Float) -> PipeVertex {
        let (bu, _) = basis(u), (bv, _) = basis(v)
        let (nbu, dbu) = basis(min(max(u, 0.002), 0.998))
        let (nbv, dbv) = basis(min(max(v, 0.002), 0.998))
        var pos = SIMD3<Float>.zero, du = SIMD3<Float>.zero, dv = SIMD3<Float>.zero
        for j in 0 ..< 4 {
            for k in 0 ..< 4 {
                let p = c[j * 4 + k]
                pos += (bu[j] * bv[k]) * p
                du += (dbu[j] * nbv[k]) * p
                dv += (nbu[j] * dbv[k]) * p
            }
        }
        let cr = simd_cross(dv, du)
        let len = simd_length(cr)
        let n = len > 1e-6 ? cr / len : SIMD3<Float>(0, 1, 0)
        return PipeVertex(pos: SIMD4(pos, 1), norm: SIMD4(n, 0))
    }

    private static func tessellate(
        _ out: inout [PipeVertex], ctrl: [SIMD3<Float>], grid: Int,
        addTri: (inout [PipeVertex], PipeVertex, PipeVertex, PipeVertex) -> Void
    ) {
        let inv = 1.0 / Float(grid)
        for j in 0 ..< grid {
            for k in 0 ..< grid {
                let u0 = Float(j) * inv, u1 = Float(j + 1) * inv
                let v0 = Float(k) * inv, v1 = Float(k + 1) * inv
                let p00 = eval(ctrl, u0, v0), p01 = eval(ctrl, u0, v1)
                let p10 = eval(ctrl, u1, v0), p11 = eval(ctrl, u1, v1)
                addTri(&out, p00, p01, p11)
                addTri(&out, p00, p11, p10)
            }
        }
    }

    private static let patchIndices: [[Int]] = """
    102 103 104 105 4 5 6 7 8 9 10 11 12 13 14 15
    12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27
    24 25 26 27 29 30 31 32 33 34 35 36 37 38 39 40
    96 96 96 96 97 98 99 100 101 101 101 101 0 1 2 3
    0 1 2 3 106 107 108 109 110 111 112 113 114 115 116 117
    118 118 118 118 124 122 119 121 123 126 125 120 40 39 38 37
    41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56
    53 54 55 56 57 58 59 60 61 62 63 64 28 65 66 67
    68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 83
    80 81 82 83 84 85 86 87 88 89 90 91 92 93 94 95
    """.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace).compactMap { Int($0) } }

    private static let points: [SIMD3<Float>] = {
        let raw = """
        0.2 0 2.7 0.2 -0.112 2.7 0.112 -0.2 2.7 0 -0.2 2.7 1.3375 0 2.53125 1.3375 -0.749 2.53125
        0.749 -1.3375 2.53125 0 -1.3375 2.53125 1.4375 0 2.53125 1.4375 -0.805 2.53125
        0.805 -1.4375 2.53125 0 -1.4375 2.53125
        1.5 0 2.4 1.5 -0.84 2.4 0.84 -1.5 2.4 0 -1.5 2.4 1.75 0 1.875 1.75 -0.98 1.875 0.98 -1.75 1.875 0 -1.75 1.875
        2 0 1.35 2 -1.12 1.35 1.12 -2 1.35 0 -2 1.35 2 0 0.9 2 -1.12 0.9 1.12 -2 0.9 0 -2 0.9 -2 0 0.9
        2 0 0.45 2 -1.12 0.45 1.12 -2 0.45 0 -2 0.45 1.5 0 0.225 1.5 -0.84 0.225 0.84 -1.5 0.225 0 -1.5 0.225
        1.5 0 0.15 1.5 -0.84 0.15 0.84 -1.5 0.15 0 -1.5 0.15 -1.6 0 2.025 -1.6 -0.3 2.025 -1.5 -0.3 2.25 -1.5 0 2.25
        -2.3 0 2.025 -2.3 -0.3 2.025 -2.5 -0.3 2.25 -2.5 0 2.25 -2.7 0 2.025 -2.7 -0.3 2.025 -3 -0.3 2.25 -3 0 2.25
        -2.7 0 1.8 -2.7 -0.3 1.8 -3 -0.3 1.8 -3 0 1.8 -2.7 0 1.575 -2.7 -0.3 1.575 -3 -0.3 1.35 -3 0 1.35
        -2.5 0 1.125 -2.5 -0.3 1.125 -2.65 -0.3 0.9375 -2.65 0 0.9375 -2 -0.3 0.9 -1.9 -0.3 0.6 -1.9 0 0.6
        1.7 0 1.425 1.7 -0.66 1.425 1.7 -0.66 0.6 1.7 0 0.6 2.6 0 1.425 2.6 -0.66 1.425 3.1 -0.66 0.825 3.1 0 0.825
        2.3 0 2.1 2.3 -0.25 2.1 2.4 -0.25 2.025 2.4 0 2.025 2.7 0 2.4 2.7 -0.25 2.4 3.3 -0.25 2.4 3.3 0 2.4
        2.8 0 2.475 2.8 -0.25 2.475 3.525 -0.25 2.49375 3.525 0 2.49375
        2.9 0 2.475 2.9 -0.15 2.475 3.45 -0.15 2.5125 3.45 0 2.5125
        2.8 0 2.4 2.8 -0.15 2.4 3.2 -0.15 2.4 3.2 0 2.4 0 0 3.15 0.8 0 3.15 0.8 -0.45 3.15 0.45 -0.8 3.15 0 -0.8 3.15
        0 0 2.85 1.4 0 2.4 1.4 -0.784 2.4 0.784 -1.4 2.4 0 -1.4 2.4
        0.4 0 2.55 0.4 -0.224 2.55 0.224 -0.4 2.55 0 -0.4 2.55
        1.3 0 2.55 1.3 -0.728 2.55 0.728 -1.3 2.55 0 -1.3 2.55 1.3 0 2.4 1.3 -0.728 2.4 0.728 -1.3 2.4 0 -1.3 2.4
        0 0 0 1.425 -0.798 0 1.5 0 0.075 1.425 0 0 0.798 -1.425 0
        0 -1.5 0.075 0 -1.425 0 1.5 -0.84 0.075 0.84 -1.5 0.075
        """
        let f = raw.split(whereSeparator: \.isWhitespace).compactMap { Float($0) }
        return stride(from: 0, to: f.count - 2, by: 3).map { SIMD3(f[$0], f[$0 + 1], f[$0 + 2]) }
    }()
}
