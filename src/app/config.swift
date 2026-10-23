import CryptoKit
import Foundation

// A pattern is everything that decides the picture. Shape, dither and palette go
// by name, so the tables can grow without repointing anything saved or shared
let kPatternNumbers = ["pixelSize", "warp", "contrast", "grain", "vignette", "zoom", "spread", "speed"]

func normalizePattern(_ d: [String: Any]) -> [String: Any] {
    func pick(_ v: Any?, _ names: [String], _ fallback: Int) -> Int {
        if let s = v as? String { return names.firstIndex { $0.caseInsensitiveCompare(s) == .orderedSame } ?? fallback }
        if let n = v as? Int, names.indices.contains(n) { return n } // looks saved before 0.5 stored indices
        return fallback
    }
    func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
    func clamp(_ x: Double, _ r: ClosedRange<Double>) -> Double {
        (min(max(x, r.lowerBound), r.upperBound) * 10_000).rounded() / 10_000
    }
    let shape = pick(d["shape"], kShapeNames, 0)
    let palettes = kPalettes.map(\.0) + (kPalettes.last?.0 == "Custom" ? [] : ["Custom"])
    var p: [String: Any] = [
        "shape": kShapeNames[shape],
        "dither": kDitherNames[pick(d["dither"], kDitherNames, 3)],
        "palette": palettes[pick(d["paletteName"] ?? d["palette"], palettes, 1)],
        "colors": Int(clamp(num(d["colors"]) ?? 5, 2 ... 5)),
        "invert": (d["invert"] as? Bool) ?? false,
        "seed": clamp(num(d["seed"]) ?? 0, 0 ... 1_000)
    ]
    for k in kPatternNumbers {
        p[k] = clamp(num(d[k]) ?? (Pref.base[k] as? Double ?? 0), kRanges[k] ?? 0 ... 1)
    }
    let given = d["params"] as? [String: Any] ?? [:]
    let ps = shapeParams(shape)
    if !ps.isEmpty {
        p["params"] = Dictionary(uniqueKeysWithValues: ps
            .map { ($0.key, clamp(num(given[$0.key]) ?? $0.def, $0.range)) })
    }
    // a Custom palette travels with its colours, or it means something else on every machine
    if p["palette"] as? String == "Custom" {
        let hex = (d["custom"] as? [String])?.compactMap(rgb) ?? PhotoPalette.stored()
        if let hex, hex.count == 5 { p["custom"] = hex.map(hexString) } else { p["palette"] = palettes[1] }
    }
    if let name = d["name"] as? String, !name.isEmpty { p["name"] = name }
    return p
}

func rgb(_ s: String) -> SIMD3<Float>? {
    guard s.count == 7, s.hasPrefix("#"), let v = UInt32(s.dropFirst(), radix: 16) else { return nil }
    return SIMD3(Float(v >> 16 & 255), Float(v >> 8 & 255), Float(v & 255)) / 255
}

func hexString(_ c: SIMD3<Float>) -> String {
    let b = (c * 255).rounded(.toNearestOrAwayFromZero)
    return String(format: "#%02x%02x%02x", Int(b.x), Int(b.y), Int(b.z))
}

// same picture, same id, on any machine: a UUIDv5 of the canonical one-line
// KYAML. The name is left out, so renaming keeps the id
private let kPatternNamespace: uuid_t = ( // 5d1f6b0e-6c9a-4a51-9f43-2e7f0c8d9a17
    0x5D, 0x1F, 0x6B, 0x0E, 0x6C, 0x9A, 0x4A, 0x51, 0x9F, 0x43, 0x2E, 0x7F, 0x0C, 0x8D, 0x9A, 0x17
)

func patternID(_ p: [String: Any]) -> String {
    var c = normalizePattern(p)
    c["name"] = nil
    let data = withUnsafeBytes(of: kPatternNamespace) { Data($0) } + Data(KYAML.emit(c, line: true).utf8)
    var h = Array(Insecure.SHA1.hash(data: data).prefix(16))
    h[6] = h[6] & 0x0F | 0x50
    h[8] = h[8] & 0x3F | 0x80
    return h.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }.uuidString.lowercased()
}

func withID(_ p: [String: Any]) -> [String: Any] {
    var n = normalizePattern(p)
    n["id"] = patternID(n)
    return n
}

func currentPattern() -> [String: Any] {
    let d = Pref.d, shape = d.integer(forKey: "shape")
    var raw: [String: Any] = [
        "shape": shape, "dither": d.integer(forKey: "dither"),
        "palette": kPalettes[min(max(d.integer(forKey: "palette"), 0), kPalettes.count - 1)].0,
        "colors": d.integer(forKey: "colors"), "invert": d.bool(forKey: "invert"), "seed": d.double(forKey: "seed")
    ]
    for k in kPatternNumbers {
        raw[k] = d.double(forKey: k)
    }
    raw["params"] = Dictionary(uniqueKeysWithValues: shapeParams(shape).map { (
        $0.key,
        d.double(forKey: paramKey(shape, $0))
    ) })
    return withID(raw)
}

func applyPattern(_ raw: [String: Any]) {
    let p = normalizePattern(raw), d = Pref.d
    if let hex = p["custom"] as? [String] { PhotoPalette.save(hex.compactMap(rgb)) }
    let shape = kShapeNames.firstIndex(of: p["shape"] as? String ?? "") ?? 0
    d.set(shape, forKey: "shape")
    d.set(kDitherNames.firstIndex(of: p["dither"] as? String ?? "") ?? 3, forKey: "dither")
    d.set(paletteIndex(p["palette"] as? String ?? "") ?? 1, forKey: "palette")
    for k in kPatternNumbers + ["colors", "invert", "seed"] {
        d.set(p[k], forKey: k)
    }
    for (k, v) in p["params"] as? [String: Any] ?? [:] {
        d.set(v, forKey: "\(shapeName(shape).lowercased()).\(k)")
    }
    d.set(false, forKey: "isPhoto")
}

// ~/.config/pixeldish/config.kyaml belongs to the app, which rewrites it on every
// change. /etc/pixeldish/config.kyaml belongs to nix-darwin and wins: its
// settings and pattern apply at launch and whenever a rebuild changes it, its
// saved patterns are listed but never written back
enum Config {
    static let settingKeys = ["animate", "hyper", "autoShuffle"]
    static var userURL: URL {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("pixeldish/config.kyaml")
    }

    static let managedURL = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["PIXELDISH_MANAGED_CONFIG"]
            ?? "/etc/pixeldish/config.kyaml"
    )
    static var managedIDs: Set<String> = []
    static var lastWritten = ""
    // a hand-edited file that no longer parses is left alone until it does
    static var userBroken = false
    static var stamps = ["", ""]

    static func read(_ url: URL) -> [String: Any]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        do {
            guard let m = try KYAML.parse(text) as? [String: Any] else { throw KYAML.Bad(description: "not a map") }
            return m
        } catch {
            FileHandle.standardError.write(Data("pixeldish: \(url.path): \(error)\n".utf8))
            return nil
        }
    }

    // a pattern is either a map or the id of a saved one
    static func resolve(_ v: Any?, _ saved: [[String: Any]]) -> [String: Any]? {
        if let m = v as? [String: Any] { return m }
        guard let s = (v as? String)?.lowercased() else { return nil }
        return saved.first { $0["id"] as? String == s }
    }

    static func load() {
        let managed = read(managedURL) ?? [:]
        let parsed = read(userURL)
        userBroken = parsed == nil && FileManager.default.fileExists(atPath: userURL.path)
        // first run after 0.4: seed the file from what UserDefaults already holds
        let user = parsed ?? [
            "settings": Dictionary(uniqueKeysWithValues: settingKeys.map { ($0, Pref.d.bool(forKey: $0)) }),
            "pattern": currentPattern(), "saved": savedLooks()
        ]
        let settings = (user["settings"] as? [String: Any] ?? [:])
            .merging(managed["settings"] as? [String: Any] ?? [:]) { $1 }
        for k in settingKeys {
            if let b = settings[k] as? Bool { Pref.d.set(b, forKey: k) }
        }
        let mine = (managed["saved"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.map(withID)
        managedIDs = Set(mine.compactMap { $0["id"] as? String })
        var seen = Set<String>()
        let saved = (mine + (user["saved"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.map(withID))
            .filter { seen.insert($0["id"] as? String ?? "").inserted }
        storeLooks(saved)
        if let p = resolve(managed["pattern"] ?? user["pattern"], saved) { applyPattern(p) }
        stamps = [stamp(managedURL), stamp(userURL)]
        save()
    }

    static func save() {
        let p = currentPattern()
        if Pref.d.string(forKey: "patternID") != p["id"] as? String { Pref.d.set(p["id"], forKey: "patternID") }
        guard !userBroken else { return }
        let doc: [String: Any] = [
            "settings": Dictionary(uniqueKeysWithValues: settingKeys.map { ($0, Pref.d.bool(forKey: $0)) }),
            "pattern": p,
            "saved": savedLooks().filter { !managedIDs.contains($0["id"] as? String ?? "") }
        ]
        let text = "# written by pixeldish on every change; nix-darwin's /etc/pixeldish/config.kyaml wins over it\n"
            + KYAML.emit(doc) + "\n"
        guard text != lastWritten else { return }
        lastWritten = text
        try? FileManager.default.createDirectory(
            at: userURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? text.write(to: userURL, atomically: true, encoding: .utf8)
        stamps[1] = stamp(userURL)
    }

    // nix swaps the /etc symlink rather than touching a file, so compare the resolved path too
    static func stamp(_ url: URL) -> String {
        let r = url.resolvingSymlinksInPath()
        let m = (try? FileManager.default.attributesOfItem(atPath: r.path))?[.modificationDate] as? Date
        return "\(r.path)@\(m?.timeIntervalSince1970 ?? 0)"
    }

    static func poll() {
        let now = [stamp(managedURL), stamp(userURL)]
        guard now != stamps else { return }
        if now[0] == stamps[0], (try? String(contentsOf: userURL, encoding: .utf8)) == lastWritten {
            stamps = now
            return
        }
        load()
    }
}

// --check: what nix runs on the config it generates, so a typo fails the build
// instead of silently falling back to a default
func patternProblems(_ d: [String: Any]) -> [String] {
    var out: [String] = []
    let known = Set(KYAML.order + ["paletteName"])
    out += d.keys.filter { !known.contains($0) }.map { "unknown key \($0)" }
    func named(_ k: String, _ names: [String]) {
        if let s = d[k] as? String, !names.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) {
            out.append("unknown \(k) \"\(s)\" (one of: \(names.joined(separator: ", ")))")
        }
    }
    named("shape", kShapeNames)
    named("dither", kDitherNames)
    named("palette", kPalettes.map(\.0) + ["Custom"])
    for k in kPatternNumbers {
        if let x = (d[k] as? NSNumber)?.doubleValue, let r = kRanges[k],
           !r.contains(x) { out.append("\(k) \(x) outside \(r)") }
    }
    let shape = kShapeNames.firstIndex { $0.caseInsensitiveCompare(d["shape"] as? String ?? "") == .orderedSame } ?? -1
    for (k, v) in d["params"] as? [String: Any] ?? [:] {
        guard let p = shape < 0 ? nil : shapeParams(shape).first(where: { $0.key == k }) else {
            out.append("\(d["shape"] ?? "?") has no param \(k)")
            continue
        }
        if let x = (v as? NSNumber)?.doubleValue, !p.range.contains(x) { out.append("\(k) \(x) outside \(p.range)") }
    }
    return out
}

func checkConfig(_ path: String) -> Bool {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("\(path): cannot read")
        return false
    }
    do {
        guard let m = try KYAML.parse(text) as? [String: Any] else { throw KYAML.Bad(description: "not a map") }
        let list = m["saved"] as? [Any] ?? []
        let saved = list.compactMap { $0 as? [String: Any] }
        var ps = m["shape"] != nil ? [m] : saved
        var bad = m["shape"] == nil ? m.keys.filter { !["settings", "pattern", "saved"].contains($0) }
            .map { "unknown key \($0)" } : []
        if saved.count < list.count { bad.append("saved takes patterns, not ids") }
        if let p = m["pattern"] as? [String: Any] { ps.insert(p, at: 0) }
        if let id = m["pattern"] as? String, Config.resolve(id, saved.map(withID)) == nil {
            bad.append("pattern \(id) is not the id of a saved pattern")
        }
        for p in ps {
            let probs = patternProblems(p)
            bad += probs
            if probs.isEmpty { print("\(patternID(p))  \(p["name"] as? String ?? p["shape"] as? String ?? "")") }
        }
        for b in bad {
            print("\(path): \(b)")
        }
        return bad.isEmpty
    } catch {
        print("\(path): \(error)")
        return false
    }
}
