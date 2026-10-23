import Foundation

// KYAML is the strict flow-style YAML subset kubectl emits: maps in {}, lists
// in [], double-quoted strings, trailing commas, # comments. Every KYAML file is
// YAML, so any YAML tool reads these; this reader only takes the subset
enum KYAML {
    struct Bad: Error, CustomStringConvertible { let description: String }

    static func parse(_ text: String) throws -> Any {
        var p = Reader(s: Array(text))
        p.skip()
        if p.s[p.i...].starts(with: "---") { p.i += 3 }
        let v = try p.value()
        p.skip()
        guard p.i == p.s.count else { throw p.bad("trailing content") }
        return v
    }

    static let order = [
        "settings", "pattern", "saved", "id", "name", "shape", "dither", "palette", "custom", "colors",
        "pixelSize", "warp", "contrast", "grain", "vignette", "zoom", "spread", "speed", "invert", "seed", "params"
    ]

    // line: one-line form, used for sharing and as the canonical text an id hashes
    static func emit(_ v: Any, indent: String = "", line: Bool = false) -> String {
        let inner = indent + "  "
        switch v {
        case let m as [String: Any]:
            if m.isEmpty { return "{}" }
            let kv = m.sorted { a, b in
                let ia = order.firstIndex(of: a.key) ?? order.count, ib = order.firstIndex(of: b.key) ?? order.count
                return ia != ib ? ia < ib : a.key < b.key
            }
            if line {
                return "{" + kv.map { "\(key($0.key)): \(emit($0.value, line: true))" }.joined(separator: ", ") + "}"
            }
            let body = kv.map { "\(inner)\(key($0.key)): \(emit($0.value, indent: inner)),\n" }
            return "{\n" + body.joined() + "\(indent)}"
        case let a as [Any]:
            if a.isEmpty { return "[]" }
            if line || !a.contains(where: { $0 is [String: Any] || $0 is [Any] }) {
                return "[" + a.map { emit($0, line: true) }.joined(separator: ", ") + "]"
            }
            return "[\n" + a.map { "\(inner)\(emit($0, indent: inner)),\n" }.joined() + "\(indent)]"
        default: return scalar(v)
        }
    }

    static func scalar(_ v: Any) -> String {
        switch v {
        case let b as Bool: b ? "true" : "false"
        case let n as Int: "\(n)"
        case let x as Double: number(x)
        case let s as String: quote(s)
        default: "null"
        }
    }

    static func number(_ x: Double) -> String {
        if x == x.rounded(), abs(x) < 1e15 { return String(Int(x)) }
        var s = String(format: "%.4f", x)
        while s.hasSuffix("0") {
            s.removeLast()
        }
        return s
    }

    static func quote(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return d.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    static func key(_ k: String) -> String {
        k.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil ? k : quote(k)
    }

    private struct Reader {
        let s: [Character]
        var i = 0

        func bad(_ m: String) -> Bad {
            Bad(description: "line \(s[..<min(i, s.count)].filter { $0 == "\n" }.count + 1): \(m)")
        }

        mutating func skip() {
            while i < s.count {
                if s[i] == "#" {
                    while i < s.count, s[i] != "\n" {
                        i += 1
                    }
                } else if s[i].isWhitespace { i += 1 } else { return }
            }
        }

        mutating func value() throws -> Any {
            skip()
            guard i < s.count else { throw bad("unexpected end") }
            switch s[i] {
            case "{": return try map()
            case "[": return try list()
            case "\"": return try string()
            default:
                let w = word()
                switch w {
                case "": throw bad("unexpected \(s[i])")
                case "true": return true
                case "false": return false
                case "null", "~": return NSNull()
                default: return Int(w).map { $0 as Any } ?? Double(w).map { $0 as Any } ?? w
                }
            }
        }

        mutating func map() throws -> [String: Any] {
            i += 1
            var m: [String: Any] = [:]
            while try !close("}") {
                skip()
                let k = s[i] == "\"" ? try string() : word()
                skip()
                guard !k.isEmpty, i < s.count, s[i] == ":" else { throw bad("expected key: value") }
                i += 1
                m[k] = try value()
                try comma("}")
            }
            return m
        }

        mutating func list() throws -> [Any] {
            i += 1
            var a: [Any] = []
            while try !close("]") {
                try a.append(value())
                try comma("]")
            }
            return a
        }

        mutating func close(_ c: Character) throws -> Bool {
            skip()
            guard i < s.count else { throw bad("missing \(c)") }
            if s[i] == c { i += 1
                return true
            }
            return false
        }

        mutating func comma(_ c: Character) throws {
            skip()
            if i < s.count, s[i] == "," { i += 1 } else if i < s.count,
                                                           s[i] == c {} else { throw bad("expected , or \(c)") }
        }

        mutating func word() -> String {
            let start = i
            while i < s.count, !" \t\r\n,:{}[]#\"".contains(s[i]) {
                i += 1
            }
            return String(s[start ..< i])
        }

        mutating func string() throws -> String {
            i += 1
            var out = ""
            while i < s.count {
                let c = s[i]
                i += 1
                if c == "\"" { return out }
                guard c == "\\" else { out.append(c)
                    continue
                }
                guard i < s.count else { break }
                let e = s[i]
                i += 1
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "u":
                    guard i + 4 <= s.count, let v = UInt32(String(s[i ..< i + 4]), radix: 16),
                          let u = Unicode.Scalar(v)
                    else { throw bad("bad \\u escape") }
                    out.unicodeScalars.append(u)
                    i += 4
                default: out.append(e)
                }
            }
            throw bad("unterminated string")
        }
    }
}
