import AppKit
import MetalKit

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WallpaperController {
    var windows: [NSWindow] = []
    var views: [MTKView] = []
    var renderers: [DishRenderer] = []

    func rebuild() {
        for w in windows {
            w.orderOut(nil)
        }
        windows = []
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

    // normally the 20 Hz app timer asks for each frame; hyper hands the view its
    // own display link at the panel's top rate. Either way a window the system
    // reports fully covered (fullscreen app, other Space) stops drawing
    func tick(live: Bool, hyper: Bool) {
        for (v, w) in zip(views, windows) {
            let run = live && w.occlusionState.contains(.visible)
            let fps = hyper ? (w.screen?.maximumFramesPerSecond ?? 120) : 20
            if v.preferredFramesPerSecond != fps { v.preferredFramesPerSecond = fps }
            let selfDriven = run && hyper
            if v.isPaused == selfDriven {
                v.isPaused = !selfDriven
                v.enableSetNeedsDisplay = !selfDriven
            }
            if run, !hyper { v.setNeedsDisplay(v.bounds) }
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
