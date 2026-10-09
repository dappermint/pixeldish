import Foundation

enum Pref {
    static let d = UserDefaults.standard
    static func register() {
        d.register(defaults: [
            "shape": 0, "dither": 3, "palette": 1, "pixelSize": 3.0, "colors": 5,
            "warp": 0.5, "contrast": 1.0, "grain": 0.05, "vignette": 0.35,
            "speed": 0.35, "zoom": 1.0, "spread": 0.0, "animate": true,
            "invert": false, "launchAtLogin": false, "hyper": false,
            "autoShuffle": false
        ])
        PhotoPalette.apply()
        if d.object(forKey: "seed") == nil { d.set(timeSeed(), forKey: "seed") }
    }
}

// seeds come from the unix clock (ms), scrambled with splitmix64 so adjacent
// milliseconds land far apart. kept under 1000 because the shader receives a
// Float and its fract() hashing loses precision on large values
func timeSeed(_ t: Double = Date().timeIntervalSince1970) -> Double {
    var x = UInt64(t * 1_000) &+ 0x9E37_79B9_7F4A_7C15
    x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
    x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
    x ^= x >> 31
    return Double(x % 1_000_000) / 1_000
}

// looks remember palettes by name: the table grows and Photo is appended last,
// so an index saved today would point at a different palette tomorrow
func paletteIndex(_ name: String) -> Int? { kPalettes.firstIndex { $0.0 == name } }

// JSON Data, not a plist array, so the editor can observe it through @AppStorage
func savedLooks(_ data: Data? = Pref.d.data(forKey: "saved")) -> [[String: Any]] {
    data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
}

func storeLooks(_ looks: [[String: Any]]) {
    if let data = try? JSONSerialization.data(withJSONObject: looks) { Pref.d.set(data, forKey: "saved") }
}

// slider ranges, measured by rendering every shape across each range: past these
// a shape goes flat (contrast < 0.7, spread > 0.2), aliases into static
// (pixel size > 6, zoom outside 0.7..1.5, grain > 0.12) or jitters (speed > 1).
// makeUniforms clamps too, so saved looks and history from wider ranges stay sane
let kRanges: [String: ClosedRange<Double>] = [
    "pixelSize": 1 ... 6, "warp": 0 ... 1, "contrast": 0.7 ... 1.8, "grain": 0 ... 0.12,
    "vignette": 0 ... 1, "zoom": 0.7 ... 1.5, "spread": 0 ... 0.2, "speed": 0 ... 1
]

func prefValue(_ key: String) -> Float {
    let v = Pref.d.double(forKey: key)
    guard let r = kRanges[key] else { return Float(v) }
    return Float(min(max(v, r.lowerBound), r.upperBound))
}
