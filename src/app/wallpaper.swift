import AppKit
import MetalKit

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WallpaperController {
    var windows: [NSWindow] = []
    var screens: [NSScreen] = []
    var views: [MTKView] = []
    var renderers: [DishRenderer] = []

    func rebuild() {
        for w in windows {
            w.orderOut(nil)
        }
        windows = []
        screens = []
        views = []
        renderers = []
        for screen in NSScreen.screens {
            let v = MTKView(frame: screen.frame, device: MTLCreateSystemDefaultDevice())
            v.colorPixelFormat = .rgba8Unorm
            v.framebufferOnly = false
            v.preferredFramesPerSecond = 20
            v.isPaused = true // we drive every frame ourselves
            v.enableSetNeedsDisplay = true
            guard let r = DishRenderer(shader: kShaderPath) else { continue }
            if ProcessInfo.processInfo.environment["PIXELDISH_PROBE"] != nil { r.probeFrames = 3 }
            v.delegate = r
            let w = WallpaperWindow(
                contentRect: screen.frame, styleMask: .borderless,
                backing: .buffered, defer: false
            )
            w.contentView = v
            w.isOpaque = true
            w.backgroundColor = .black
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            // the window server insets a borderless window by ~2% and centres it,
            // which leaves a frame of the real wallpaper showing, so oversize it
            w.setFrame(screen.frame.insetBy(dx: -80, dy: -80), display: true)
            w.orderFrontRegardless()
            windows.append(w)
            screens.append(screen)
            views.append(v)
            renderers.append(r)
        }
    }

    var paused = false
    func setPaused(_ p: Bool) {
        paused = p
        for r in renderers {
            r.paused = p
        }
    }

    // normally the 20 Hz app timer asks for each frame; pipes hands the view its own
    // display link at the fps slider's rate, eased down as windows cover more of the
    // display, and hyper runs at the panel's top rate. A fully covered window
    // (fullscreen app, other Space) stops drawing
    func tick(live: Bool, hyper: Bool, recount: Bool = false) {
        let shape = Pref.d.integer(forKey: "shape"), photo = Pref.d.bool(forKey: "isPhoto")
        if recount || visible.count != screens.count { visible = visibleShares(screens.map(\.frame)) }
        for (i, (v, w)) in zip(views, windows).enumerated() {
            let run = live && w.occlusionState.contains(.visible)
            let fps = targetFPS(
                shape: shape, isPhoto: photo, hyper: hyper, fps: Double(prefValue("fps")),
                visible: visible[i], maxFPS: w.screen?.maximumFramesPerSecond ?? 120
            )
            if v.preferredFramesPerSecond != fps { v.preferredFramesPerSecond = fps }
            let selfDriven = run && fps != 20
            if v.isPaused == selfDriven {
                v.isPaused = !selfDriven
                v.enableSetNeedsDisplay = !selfDriven
            }
            if run, !selfDriven { v.setNeedsDisplay(v.bounds) }
        }
    }

    var visible: [Double] = []
    func visibleShares(_ frames: [CGRect]) -> [Double] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let rects = list.compactMap { info -> CGRect? in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = info[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            return CGRect(dictionaryRepresentation: b)
        }
        // CG window bounds are top-left origin on the primary display, NSScreen frames bottom-left
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return frames.map { f in
            visibleShare(CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height), covers: rects)
        }
    }

    // one redraw, for when a setting changed while the wallpaper is frozen
    func refresh() {
        for v in views {
            v.setNeedsDisplay(v.bounds)
        }
    }

    func loadPhoto(_ url: URL) { renderers.forEach { $0.loadPhoto(url) } }
    func reset() { renderers.forEach { $0.start = Date() } }
}

// ponytail: samples a 32x20 grid instead of a true rect union; a window under one
// cell (~3% of a display) can be missed, plenty for picking a frame rate
func visibleShare(_ screen: CGRect, covers: [CGRect]) -> Double {
    let cols = 32, rows = 20
    var open = 0
    for r in 0 ..< rows {
        for c in 0 ..< cols {
            let p = CGPoint(
                x: screen.minX + (Double(c) + 0.5) * screen.width / Double(cols),
                y: screen.minY + (Double(r) + 0.5) * screen.height / Double(rows)
            )
            if !covers.contains(where: { $0.contains(p) }) { open += 1 }
        }
    }
    return Double(open) / Double(cols * rows)
}
