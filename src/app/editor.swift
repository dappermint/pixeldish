import ServiceManagement
import SwiftUI

// every row's control column, so sliders and segmented pickers share both edges
private let kControlWidth: CGFloat = 230

struct EditorView: View {
    @AppStorage("shape") var shape = 0
    @AppStorage("dither") var dither = 3
    @AppStorage("palette") var palette = 1
    @AppStorage("pixelSize") var pixelSize = 3.0
    @AppStorage("colors") var colors = 5
    @AppStorage("warp") var warp = 0.5
    @AppStorage("contrast") var contrast = 1.0
    @AppStorage("grain") var grain = 0.05
    @AppStorage("vignette") var vignette = 0.35
    @AppStorage("speed") var speed = 0.35
    @AppStorage("zoom") var zoom = 1.0
    @AppStorage("spread") var spread = 0.0
    @AppStorage("animate") var animate = true
    @AppStorage("invert") var invert = false
    @AppStorage("hyper") var hyper = false
    @AppStorage("fps") var fps = 60.0
    @AppStorage("autoShuffle") var autoShuffle = false
    @AppStorage("isPhoto") var isPhoto = false
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("seed") var seed = 0.0
    @AppStorage("saved") var savedData = Data()
    @AppStorage("patternID") var patternID = ""
    var onShuffle: () -> Void
    var onReseed: () -> Void
    var onSave: () -> Void
    var onLoad: (Int) -> Void
    var onDelete: (Int) -> Void
    var onPrevious: () -> Void
    var onCopy: () -> Void
    var onPaste: () -> Void
    var onPhoto: () -> Void
    var onPalettePhoto: () -> Void
    var onStill: () -> Void
    var onExport: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Shape", selection: $shape) {
                    ForEach(0 ..< kShapeNames.count, id: \.self) { Text(kShapeNames[$0]).tag($0) }
                }
                Picker("Dither", selection: $dither) {
                    ForEach(0 ..< kDitherNames.count, id: \.self) { Text(kDitherNames[$0]).tag($0) }
                }
                Picker("Palette", selection: $palette) {
                    ForEach(0 ..< kPalettes.count, id: \.self) { Text(kPalettes[$0].0).tag($0) }
                }
                LabeledContent("Custom") {
                    HStack(spacing: 6) {
                        ForEach(0 ..< 5, id: \.self) { i in
                            ColorPicker("Custom colour \(i + 1)", selection: customColor(i), supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                }
                Button("Palette from photo...", action: onPalettePhoto)
            }

            if !shapeParams(shape).isEmpty {
                Section(shapeName(shape)) {
                    ForEach(shapeParams(shape), id: \.key) { p in
                        ParamSlider(param: p, key: paramKey(shape, p)).id(paramKey(shape, p))
                    }
                    if shapeName(shape) == "Pipes" {
                        slider("Frame rate", $fps, "fps", format: "%.0f")
                            .help("drops with how much of the display windows cover; hyper ignores it")
                    }
                }
            }

            Section("Tuning") {
                segmented("Colours", $colors, 2 ... 5)
                segmented("Pixel size", Binding(
                    get: { Int(min(max(pixelSize, 1), 6)) },
                    set: { pixelSize = Double($0) }
                ), 1 ... 6)
                slider("Warp", $warp, "warp")
                slider("Contrast", $contrast, "contrast")
                slider("Grain", $grain, "grain")
                slider("Vignette", $vignette, "vignette")
                slider("Zoom", $zoom, "zoom")
                slider("Spread", $spread, "spread")
                slider("Speed", $speed, "speed")
            }

            Section("Behaviour") {
                Toggle("Animate", isOn: $animate)
                Toggle("Invert", isOn: $invert)
                Toggle("Hyper", isOn: $hyper)
                    .help("demo mode: draw at the display's top refresh rate, 120 Hz on ProMotion")
                Toggle("Shuffle every hour", isOn: $autoShuffle)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? (on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister())
                    }
            }

            Section {
                HStack {
                    Button("Shuffle", action: onShuffle)
                    Button("Reseed", action: onReseed)
                    Button("Previous", action: onPrevious)
                }
                LabeledContent("Seed", value: String(format: "%.3f", seed))
                    .monospacedDigit().textSelection(.enabled)
                LabeledContent("Pattern ID") {
                    Text(patternID).font(.caption.monospaced()).textSelection(.enabled)
                }
                HStack {
                    Button("Copy pattern", action: onCopy)
                    Button("Paste pattern", action: onPaste)
                }
                HStack {
                    Button("Use a photo", action: onPhoto)
                    Button("Still frame", action: onStill)
                    Button("Export PNG", action: onExport)
                }
                if isPhoto {
                    Button("Back to generators") { isPhoto = false }
                }
            }

            Section {
                if savedLooks(savedData).isEmpty {
                    Text("No saved looks yet").foregroundStyle(.secondary)
                }
                ForEach(Array(savedLooks(savedData).enumerated()), id: \.offset) { i, look in
                    HStack {
                        Button(look["name"] as? String ?? "look \(i + 1)") { onLoad(i) }
                            .buttonStyle(.link).help(look["id"] as? String ?? "")
                        Spacer()
                        Button {
                            onDelete(i)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete saved look")
                    }
                }
            } header: {
                HStack {
                    Text("Saved")
                    Spacer()
                    Button("Save look", action: onSave)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 760)
    }

    // ponytail: wells read UserDefaults directly, so a palette-from-photo made while
    // Custom is already selected shows after the editor reopens; observe it if that bites
    func customColor(_ i: Int) -> Binding<Color> {
        let seed = { PhotoPalette.stored() ?? kPalettes[min(max(palette, 0), kPalettes.count - 1)].1 }
        return Binding(
            get: { let c = seed()[i]
                return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
            },
            set: { color in
                guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                var pal = seed()
                pal[i] = SIMD3(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
                PhotoPalette.save(pal)
                palette = kPalettes.count - 1
            }
        )
    }

    // reads through the clamp so a value stored by an older, wider range shows what renders
    func segmented(_ label: String, _ v: Binding<Int>, _ r: ClosedRange<Int>) -> some View {
        LabeledContent(label) {
            Picker(label, selection: v) {
                ForEach(r, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().frame(width: kControlWidth, alignment: .trailing)
        }
    }

    func slider(_ label: String, _ raw: Binding<Double>, _ key: String, format: String = "%.2f") -> some View {
        guard let r = kRanges[key] else { preconditionFailure("no slider range for \(key)") }
        let v = Binding(
            get: { min(max(raw.wrappedValue, r.lowerBound), r.upperBound) },
            set: { raw.wrappedValue = $0 }
        )
        return LabeledContent(label) {
            HStack {
                Slider(value: v, in: r).labelsHidden()
                Text(String(format: format, v.wrappedValue)).monospacedDigit()
                    .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            }
            .frame(width: kControlWidth)
        }
    }
}

// one per shape knob; the key is only known at runtime, so it owns its AppStorage
struct ParamSlider: View {
    let param: ShapeParam
    @AppStorage var value: Double

    init(param: ShapeParam, key: String) {
        self.param = param
        _value = AppStorage(wrappedValue: param.def, key)
    }

    var body: some View {
        let r = param.range
        let v = Binding(get: { min(max(value, r.lowerBound), r.upperBound) }, set: { value = $0 })
        LabeledContent(param.label) {
            HStack {
                Slider(value: v, in: r).labelsHidden()
                Text(String(format: r.upperBound - r.lowerBound >= 10 ? "%.0f" : "%.2f", v.wrappedValue))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            }
            .frame(width: kControlWidth)
        }
    }
}
