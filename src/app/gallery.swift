import SwiftUI

// Select SwiftUI's property wrapper. The State macro in newer SDKs starts
// a compiler plugin sandbox that cannot nest inside a Nix build.
private typealias ViewState<Value> = State<Value>

struct GalleryLook: Identifiable {
    let pattern: [String: Any]
    let id: String

    init(_ raw: [String: Any]) {
        pattern = normalizePattern(raw)
        id = patternID(pattern)
    }

    var name: String { pattern["name"] as? String ?? shape }
    var shape: String { pattern["shape"] as? String ?? "Drift" }
    var palette: String { pattern["palette"] as? String ?? "Dusk" }
    var dither: String { pattern["dither"] as? String ?? "Bayer 8" }

    func variations(_ axis: VariationAxis) -> [GalleryLook] {
        let original = axis == .palette ? palette : dither
        let alternatives = axis == .palette ? ["Dracula", "Ember", "Nord", "Moss"] : [
            "Bayer 4",
            "Bayer 8",
            "R2",
            "Smooth"
        ]
        return [self] + alternatives.filter { $0 != original }.prefix(3).map { value in
            var variant = pattern
            variant[axis.rawValue] = value
            return GalleryLook(variant)
        }
    }

    static let presets: [GalleryLook] = {
        let wake: [String: Any] = ["shape": "Wake", "seed": 2.1, "pixelSize": 1, "grain": 0, "vignette": 0.15]
        return [
            wake.merging(["name": "Dracula Wake", "palette": "Dracula", "dither": "Bayer 4"]) { _, new in new },
            wake.merging(["name": "Ember Wake", "palette": "Ember", "dither": "Bayer 8"]) { _, new in new },
            [
                "name": "Iris Cells",
                "shape": "Voronoi",
                "palette": "Iris",
                "dither": "Bayer 16",
                "seed": 397.996,
                "warp": 0.2039,
                "zoom": 0.7
            ],
            ["name": "Van Helsing Pipes", "shape": "Pipes", "palette": "Van Helsing", "seed": 17.2, "pixelSize": 1],
            ["name": "Dust Lanes", "shape": "Protodisk", "palette": "Ember", "seed": 2.1, "pixelSize": 1],
            ["name": "Magnetar Flare", "shape": "Magnetar", "palette": "Mocha", "seed": 2.1, "pixelSize": 1]
        ].map(GalleryLook.init)
    }()

    func thumbnailUniforms() -> Uniforms {
        func number(_ key: String) -> Float { (pattern[key] as? NSNumber)?.floatValue ?? 0 }
        let shapeIndex = kShapeNames.firstIndex(of: shape) ?? 0
        let colors = pattern["colors"] as? Int ?? 5
        var u = Uniforms()
        u.look = SIMD4(
            Float(shapeIndex),
            Float(kDitherNames.firstIndex(of: dither) ?? 3),
            number("pixelSize"),
            Float(colors)
        )
        u.tune = SIMD4(number("warp"), number("contrast"), number("grain"), number("vignette"))
        u.misc = SIMD4(
            number("seed"),
            pattern["invert"] as? Bool == true ? 1 : 0,
            24 * number("speed"),
            number("spread")
        )
        u.view = SIMD4(384, 216, number("zoom"), 0)
        let params = pattern["params"] as? [String: Double] ?? [:]
        u.setParams(shapeIndex) { params[$0.key] ?? $0.def }
        if let hex = pattern["custom"] as? [String] {
            u.setPalette(PhotoPalette.sorted(hex.compactMap(rgb)), colors: colors)
        } else {
            u.setPalette(kPalettes[paletteIndex(palette) ?? 1].1, colors: colors)
        }
        return u
    }
}

// Each thumbnail starts from its own simulation state. Browsing never advances the live renderer.
actor GalleryThumbnails {
    static let shared = GalleryThumbnails()
    private lazy var renderer = DishRenderer(shader: kShaderPath)
    private let cache = NSCache<NSString, CGImage>()

    init() {
        cache.totalCostLimit = 24 * 1_024 * 1_024
    }

    func image(id: String, uniforms: Uniforms) -> CGImage? {
        if let cached = cache.object(forKey: id as NSString) { return cached }
        guard !Task.isCancelled, let renderer else { return nil }
        renderer.particles.clear()
        renderer.wake.clear()
        let w = Int(uniforms.view.x), h = Int(uniforms.view.y)
        guard let pixels = renderer.render(uniforms, w: w, h: h), let image = cgImage(pixels, w: w, h: h)
        else { return nil }
        cache.setObject(image, forKey: id as NSString, cost: image.bytesPerRow * image.height)
        return image
    }
}

struct GalleryView: View {
    @AppStorage("saved") private var savedData = Data()
    @AppStorage("patternID") private var activeID = ""
    @AppStorage("isPhoto") private var isPhoto = false
    @ViewState private var renaming: GalleryLook?
    @ViewState private var varying: GalleryLook?
    let onApply: ([String: Any]) -> Void
    let onSave: () -> Void
    let onRename: (String, String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        let saved = savedLooks(savedData).map(GalleryLook.init)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Presets").font(.title2.bold())
                grid(GalleryLook.presets, saved: false)
                Divider().padding(.vertical, 4)
                HStack {
                    Text("Saved").font(.title2.bold())
                    Spacer()
                    Button("Save current look", action: onSave)
                        .disabled(isPhoto || saved.contains { $0.id == activeID })
                }
                if saved.isEmpty {
                    Text("No saved looks yet").foregroundStyle(.secondary)
                } else {
                    grid(saved, saved: true)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 440, minHeight: 400)
        .sheet(item: $renaming) { look in
            RenameLookView(name: look.name) { onRename(look.id, $0) }
        }
        .sheet(item: $varying) { look in
            VariationsView(base: look, onApply: onApply)
        }
    }

    private func grid(_ looks: [GalleryLook], saved: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 176), spacing: 14)], spacing: 16) {
            ForEach(looks) { look in
                let current = !isPhoto && activeID == look.id
                VStack(alignment: .leading, spacing: 5) {
                    Button { onApply(look.pattern) } label: {
                        GalleryTile(look: look, current: current)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Apply \(look.name)")
                    .accessibilityAddTraits(current ? .isSelected : [])
                    HStack {
                        Text("\(look.shape) · \(look.palette) · \(look.dither)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Menu {
                            Button("Variations…") { varying = look }
                            if saved, !Config.managedIDs.contains(look.id) {
                                Divider()
                                Button("Rename…") { renaming = look }
                                Button("Delete", role: .destructive) { onDelete(look.id) }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .accessibilityLabel("Options for \(look.name)")
                    }
                }
            }
        }
    }
}

enum VariationAxis: String {
    case palette, dither
}

private struct VariationsView: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var axis = VariationAxis.palette
    @AppStorage("patternID") private var activeID = ""
    @AppStorage("isPhoto") private var isPhoto = false
    let base: GalleryLook
    let onApply: ([String: Any]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(base.name) variations").font(.title2.bold())
            Picker("Compare", selection: $axis) {
                Text("Palette").tag(VariationAxis.palette)
                Text("Dither").tag(VariationAxis.dither)
            }
            .pickerStyle(.segmented)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(base.variations(axis)) { look in
                    let title = axis == .palette ? look.palette : look.dither
                    let label = look.id == base.id ? "\(title) (original)" : title
                    Button {
                        onApply(look.pattern)
                        dismiss()
                    } label: {
                        GalleryTile(look: look, current: !isPhoto && activeID == look.id, title: label)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Apply \(label) variation")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct RenameLookView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingName: Bool
    @ViewState var name: String
    let onRename: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename look").font(.headline)
            TextField("Name", text: $name).focused($editingName)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    onRename(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { editingName = true }
    }
}

private struct GalleryTile: View {
    let look: GalleryLook
    let current: Bool
    var title: String?
    @ViewState private var image: CGImage?
    @ViewState private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Color(nsColor: .underPageBackgroundColor)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1).resizable()
                    } else if failed {
                        Text("Preview unavailable").font(.caption)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Text(title ?? look.name).font(.headline).lineLimit(1)
                Spacer()
                if current {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).accessibilityLabel("Current")
                }
            }
        }
        .contentShape(Rectangle())
        .task(id: look.id) {
            let preview = await GalleryThumbnails.shared.image(id: look.id, uniforms: look.thumbnailUniforms())
            guard !Task.isCancelled else { return }
            image = preview
            failed = preview == nil
        }
    }
}

extension AppDelegate {
    @objc func openGallery() {
        if gallery == nil {
            let view = GalleryView(
                onApply: { [weak self] in self?.selectLook($0) },
                onSave: { [weak self] in self?.saveLook() },
                onRename: { [weak self] in self?.renameSaved($0, to: $1) },
                onDelete: { [weak self] in self?.deleteSaved($0) }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Gallery"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 720, height: 620))
            window.isReleasedWhenClosed = false
            window.center()
            gallery = window
        }
        gallery?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
