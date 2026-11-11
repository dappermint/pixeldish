struct ShapeParam {
    let key: String, label: String, range: ClosedRange<Double>, def: Double
}

// knobs one shape has beyond the shared ones, packed into Uniforms.shp in this
// order. Keyed by name like the palettes, so appending a shape moves nothing
let kShapeParams: [String: [ShapeParam]] = [
    "Torus": [
        ShapeParam(key: "size", label: "Size", range: 0.5 ... 1.5, def: 1),
        ShapeParam(key: "thickness", label: "Thickness", range: 0.1 ... 0.45, def: 0.25),
        ShapeParam(key: "tumble", label: "Tumble", range: 0 ... 3, def: 1),
        ShapeParam(key: "chase", label: "Chase", range: 0 ... 3, def: 1),
        ShapeParam(key: "windings", label: "Windings", range: 1 ... 12, def: 6)
    ],
    "Kerr": [
        ShapeParam(key: "spin", label: "Spin", range: 0 ... 0.998, def: 0.9),
        ShapeParam(key: "inclination", label: "Inclination", range: 5 ... 89, def: 80),
        ShapeParam(key: "mass", label: "Mass", range: 0.5 ... 2, def: 1),
        ShapeParam(key: "temperature", label: "Disk temperature", range: 0.5 ... 2, def: 1),
        ShapeParam(key: "disk", label: "Disk radius", range: 8 ... 30, def: 20)
    ],
    "Binary": [
        ShapeParam(key: "massRatio", label: "Mass ratio", range: 0.1 ... 1, def: 0.7),
        ShapeParam(key: "separation", label: "Separation", range: 16 ... 50, def: 34),
        ShapeParam(key: "inclination", label: "Inclination", range: 30 ... 89, def: 75),
        ShapeParam(key: "orbit", label: "Orbit speed", range: 0 ... 3, def: 1),
        ShapeParam(key: "temperature", label: "Disk temperature", range: 0.5 ... 2, def: 1)
    ],
    "Cygnus": [
        ShapeParam(key: "starMass", label: "Star mass", range: 1 ... 4, def: 2),
        ShapeParam(key: "inclination", label: "Inclination", range: 30 ... 89, def: 70),
        ShapeParam(key: "orbit", label: "Orbit speed", range: 0 ... 3, def: 1),
        ShapeParam(key: "stream", label: "Stream", range: 0 ... 1, def: 0.5),
        ShapeParam(key: "temperature", label: "Disk temperature", range: 0.5 ... 2, def: 1)
    ],
    "Pipes": [
        ShapeParam(key: "radius", label: "Pipe radius", range: 0.08 ... 0.28, def: 0.16),
        ShapeParam(key: "joints", label: "Joint style", range: 0 ... 2, def: 1),
        ShapeParam(key: "scale", label: "Grid scale", range: 0.5 ... 2.0, def: 1),
        ShapeParam(key: "speed", label: "Travel speed", range: 0 ... 3, def: 1),
        ShapeParam(key: "shine", label: "Highlight", range: 0.2 ... 2.5, def: 1.2)
    ],
    "Protodisk": [
        ShapeParam(key: "inclination", label: "Inclination", range: 0 ... 85, def: 60),
        ShapeParam(key: "mass", label: "Disk mass", range: 0 ... 0.3, def: 0.15),
        ShapeParam(key: "planet", label: "Planet mass", range: 0 ... 4, def: 1),
        ShapeParam(key: "cooling", label: "Cooling time", range: 1 ... 12, def: 5),
        ShapeParam(key: "density", label: "Particle density", range: 0.01 ... 0.3, def: 0.15),
        ShapeParam(key: "dust", label: "Dust share", range: 0 ... 0.6, def: 0.3)
    ],
    "Magnetar": [
        ShapeParam(key: "inclination", label: "Inclination", range: 0 ... 90, def: 75),
        ShapeParam(key: "obliquity", label: "Obliquity", range: 0 ... 80, def: 25),
        ShapeParam(key: "loops", label: "Loops", range: 8 ... 160, def: 48),
        ShapeParam(key: "flare", label: "Flare period", range: 3 ... 20, def: 7),
        ShapeParam(key: "density", label: "Particle density", range: 0.01 ... 0.3, def: 0.2)
    ]
]

func shapeName(_ i: Int) -> String { kShapeNames[min(max(i, 0), kShapeNames.count - 1)] }
func shapeParams(_ shape: Int) -> [ShapeParam] { kShapeParams[shapeName(shape)] ?? [] }
func paramKey(_ shape: Int, _ p: ShapeParam) -> String { "\(shapeName(shape).lowercased()).\(p.key)" }
