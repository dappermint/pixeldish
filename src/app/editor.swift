import ServiceManagement
import SwiftUI

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
    @AppStorage("isPhoto") var isPhoto = false
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("seed") var seed = 0.0
    @AppStorage("saved") var savedData = Data()
    var onShuffle: () -> Void
    var onReseed: () -> Void
    var onSave: () -> Void
    var onLoad: (Int) -> Void
    var onDelete: (Int) -> Void
    var onPrevious: () -> Void
    var onPhoto: () -> Void
    var onPalettePhoto: () -> Void
    var onStill: () -> Void
    var onExport: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pixeldish").font(.system(size: 20, weight: .semibold))
                Text("dithered wallpapers, live").font(.caption).foregroundStyle(.secondary)

                Picker("Shape", selection: $shape) {
                    ForEach(0 ..< kShapeNames.count, id: \.self) { Text(kShapeNames[$0]).tag($0) }
                }
                Picker("Dither", selection: $dither) {
                    ForEach(0 ..< kDitherNames.count, id: \.self) { Text(kDitherNames[$0]).tag($0) }
                }
                Picker("Palette", selection: $palette) {
                    ForEach(0 ..< kPalettes.count, id: \.self) { Text(kPalettes[$0].0).tag($0) }
                }

                HStack {
                    Text("Custom").font(.caption)
                    Spacer()
                    ForEach(0 ..< 5, id: \.self) { i in
                        ColorPicker("Custom colour \(i + 1)", selection: customColor(i), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
                sliderInt("Colours", $colors, 2 ... 5)
                slider("Pixel size", $pixelSize, "pixelSize", step: 1, fmt: "%.0f")
                slider("Warp", $warp, "warp", fmt: "%.2f")
                slider("Contrast", $contrast, "contrast", fmt: "%.2f")
                slider("Grain", $grain, "grain", fmt: "%.3f")
                slider("Vignette", $vignette, "vignette", fmt: "%.2f")
                slider("Zoom", $zoom, "zoom", fmt: "%.2f")
                slider("Spread", $spread, "spread", fmt: "%.2f")
                slider("Speed", $speed, "speed", fmt: "%.2f")

                HStack {
                    Toggle("Animate", isOn: $animate)
                    Toggle("Invert", isOn: $invert)
                    Toggle("Hyper", isOn: $hyper)
                        .help("demo mode: draw at the display's top refresh rate, 120 Hz on ProMotion")
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? (on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister())
                    }
                HStack {
                    Button("Shuffle", action: onShuffle)
                    Button("Reseed", action: onReseed)
                    Button("Previous", action: onPrevious)
                }
                Text(String(format: "seed %.3f", seed)).font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Use a photo", action: onPhoto)
                    Button("Still frame", action: onStill)
                    Button("Export PNG", action: onExport)
                }
                Button("Palette from photo...", action: onPalettePhoto)
                if isPhoto {
                    Button("Back to generators") { isPhoto = false }
                }

                Divider()
                HStack {
                    Text("Saved").font(.headline)
                    Spacer()
                    Button("Save look", action: onSave)
                }
                ForEach(Array(savedLooks(savedData).enumerated()), id: \.offset) { i, look in
                    HStack {
                        Button(look["name"] as? String ?? "look \(i + 1)") { onLoad(i) }
                            .buttonStyle(.link)
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
            }
            .padding(20)
        }
        .frame(width: 340, height: 720)
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

    func sliderInt(_ label: String, _ v: Binding<Int>, _ r: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text("\(v.wrappedValue)").font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(v.wrappedValue) },
                    set: { v.wrappedValue = Int($0.rounded()) }
                ),
                in: Double(r.lowerBound) ... Double(r.upperBound), step: 1
            )
        }
    }

    // reads through the clamp so a value stored by an older, wider range shows what renders
    func slider(
        _ label: String, _ raw: Binding<Double>, _ key: String,
        step: Double? = nil, fmt: String
    ) -> some View {
        guard let r = kRanges[key] else { preconditionFailure("no slider range for \(key)") }
        let v = Binding(
            get: { min(max(raw.wrappedValue, r.lowerBound), r.upperBound) },
            set: { raw.wrappedValue = $0 }
        )
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: fmt, v.wrappedValue)).font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let step { Slider(value: v, in: r, step: step) } else { Slider(value: v, in: r) }
        }
    }
}
