import MetalKit
import ScreenSaver

// runs inside Apple's sandboxed legacyScreenSaver host, so Bundle.main and
// UserDefaults.standard belong to the host. The look comes from the app's own
// prefs plist (the host may read any path) and only ever lands in the
// registration domain, nothing is written
@objc(PixeldishSaverView)
final class PixeldishSaverView: ScreenSaverView {
    let mtk: MTKView
    let renderer: DishRenderer

    override init?(frame: NSRect, isPreview: Bool) {
        guard let path = Bundle(for: PixeldishSaverView.self).path(forResource: "shader", ofType: "metallib"),
              let r = DishRenderer(shader: path)
        else { return nil }
        renderer = r
        mtk = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: r.device)
        super.init(frame: frame, isPreview: isPreview)
        mtk.colorPixelFormat = .rgba8Unorm
        mtk.autoresizingMask = [.width, .height]
        mtk.isPaused = true
        mtk.enableSetNeedsDisplay = false
        mtk.delegate = r
        addSubview(mtk)
        animationTimeInterval = isPreview ? 1.0 / 10.0 : 1.0 / 20.0
    }

    required init?(coder: NSCoder) { nil }

    override func startAnimation() {
        Self.loadLook()
        let fps = isPreview ? 15 : targetFPS(
            shape: Pref.d.integer(forKey: "shape"), isPhoto: false,
            hyper: Pref.d.bool(forKey: "hyper"), fps: Double(prefValue("fps")),
            maxFPS: window?.screen?.maximumFramesPerSecond ?? 120
        )
        animationTimeInterval = 1.0 / Double(fps)
        renderer.start = Date()
        super.startAnimation()
    }

    override func animateOneFrame() { mtk.draw() }

    override var hasConfigureSheet: Bool { false }

    // ponytail: a photo look can't be reloaded from here, so it falls back to its shape
    static func loadLook() {
        guard let pw = getpwuid(getuid()) else { return }
        let plist = String(cString: pw.pointee.pw_dir) + "/Library/Preferences/lgbt.dappy.pixeldish.plist"
        let saved = NSDictionary(contentsOfFile: plist) as? [String: Any] ?? [:]
        let fixed: [String: Any] = ["isPhoto": false, "seed": saved["seed"] ?? timeSeed()]
        Pref.d.register(defaults: Pref.base.merging(saved) { $1 }.merging(fixed) { $1 })
        PhotoPalette.apply()
    }
}
