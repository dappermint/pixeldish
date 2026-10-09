import AppKit
import MetalKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    let wall = WallpaperController()
    var status: NSStatusItem?
    var editor: NSWindow?
    var tick: Timer?
    var lastShuffle = Date()
    var history: [[String: Any]] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        Pref.register()
        history = (Pref.d.array(forKey: "history") as? [[String: Any]]) ?? []
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        wall.rebuild()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.wall.rebuild()
        }
        // one timer drives every display so they stay in step, and a still
        // wallpaper costs nothing because nothing redraws until a setting changes
        tick = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let on = Pref.d.bool(forKey: "animate")
            if on != !wall.paused { wall.setPaused(!on) }
            wall.tick(live: live, hyper: Pref.d.bool(forKey: "hyper"))
            // ponytail: fixed hour, counted from launch or the last shuffle; a picker if anyone wants daily
            if Pref.d.bool(forKey: "autoShuffle"), Date().timeIntervalSince(lastShuffle) > 3_600 { shuffle() }
        }
        wall.setPaused(!Pref.d.bool(forKey: "animate"))
        wall.refresh()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if !live { wall.refresh() }
        }
    }

    // Low Power Mode holds the current frame; settings still redraw it
    var live: Bool { Pref.d.bool(forKey: "animate") && !ProcessInfo.processInfo.isLowPowerModeEnabled }

    func buildStatusItem() {
        let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        s.button?.image = NSImage(
            systemSymbolName: "square.grid.3x3.fill",
            accessibilityDescription: "Pixeldish"
        )
        let m = NSMenu()
        m.addItem(withTitle: "Editor", action: #selector(openEditor), keyEquivalent: "e")
        m.addItem(withTitle: "Shuffle", action: #selector(shuffle), keyEquivalent: "r")
        m.addItem(withTitle: "Previous", action: #selector(previous), keyEquivalent: "p")
        m.addItem(withTitle: "Save look", action: #selector(saveLook), keyEquivalent: "s")
        m.addItem(.separator())
        m.addItem(
            withTitle: "Quit Pixeldish", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        for i in m.items where i.action != #selector(NSApplication.terminate(_:)) {
            i.target = self
        }
        s.menu = m
        status = s
    }

    // a Look is just the four things that decide a wallpaper, so history is a stack of them
    func currentLook() -> [String: Any] {
        let d = Pref.d
        return [
            "shape": d.integer(forKey: "shape"), "dither": d.integer(forKey: "dither"),
            "palette": d.integer(forKey: "palette"), "seed": d.double(forKey: "seed"),
            "pixelSize": d.double(forKey: "pixelSize"), "colors": d.integer(forKey: "colors"),
            "warp": d.double(forKey: "warp"), "contrast": d.double(forKey: "contrast"),
            "grain": d.double(forKey: "grain"), "vignette": d.double(forKey: "vignette"),
            "spread": d.double(forKey: "spread"), "invert": d.bool(forKey: "invert"),
            "paletteName": kPalettes[min(max(d.integer(forKey: "palette"), 0), kPalettes.count - 1)].0
        ]
    }

    static let lookKeys: Set<String> = [
        "shape", "dither", "palette", "seed", "pixelSize", "colors",
        "warp", "contrast", "grain", "vignette", "spread", "invert"
    ]

    func apply(_ look: [String: Any]) {
        let d = Pref.d
        for (k, v) in look where Self.lookKeys.contains(k) {
            d.set(v, forKey: k)
        }
        if let name = look["paletteName"] as? String, let i = paletteIndex(name) { d.set(i, forKey: "palette") }
        d.set(false, forKey: "isPhoto")
    }

    func pushHistory() {
        history.append(currentLook())
        if history.count > 24 { history.removeFirst() }
        Pref.d.set(history, forKey: "history")
    }

    @objc func shuffle() {
        lastShuffle = Date()
        pushHistory()
        let d = Pref.d
        d.set(Int.random(in: 0 ..< kShapeNames.count), forKey: "shape")
        d.set(Int.random(in: 0 ..< kDitherNames.count), forKey: "dither")
        d.set(Int.random(in: 0 ..< kPalettes.count), forKey: "palette")
        d.set(timeSeed(), forKey: "seed")
        d.set(false, forKey: "isPhoto")
        wall.reset()
        wall.refresh()
    }

    func reseed() {
        pushHistory()
        Pref.d.set(timeSeed(), forKey: "seed")
        wall.reset()
        wall.refresh()
    }

    // ponytail: saved looks are a flat UserDefaults array with auto names, no
    // thumbnails or rename; add a gallery if the list gets long
    @objc func saveLook() {
        var look = currentLook()
        let df = DateFormatter()
        df.dateFormat = "MMM d HH:mm"
        look["name"] =
            "\(kShapeNames[min(max(Pref.d.integer(forKey: "shape"), 0), kShapeNames.count - 1)])"
                + " / \(look["paletteName"] as? String ?? "?") / \(df.string(from: Date()))"
        storeLooks([look] + savedLooks())
    }

    func loadSaved(_ i: Int) {
        let s = savedLooks()
        guard s.indices.contains(i) else { return }
        pushHistory()
        apply(s[i])
        wall.reset()
        wall.refresh()
    }

    func deleteSaved(_ i: Int) {
        var s = savedLooks()
        guard s.indices.contains(i) else { return }
        s.remove(at: i)
        storeLooks(s)
    }

    @objc func previous() {
        guard let last = history.popLast() else { return }
        Pref.d.set(history, forKey: "history")
        apply(last)
        wall.reset()
        wall.refresh()
    }

    @objc func openEditor() {
        if let e = editor { e.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = EditorView(
            onShuffle: { [weak self] in self?.shuffle() },
            onReseed: { [weak self] in self?.reseed() },
            onSave: { [weak self] in self?.saveLook() },
            onLoad: { [weak self] in self?.loadSaved($0) },
            onDelete: { [weak self] in self?.deleteSaved($0) },
            onPrevious: { [weak self] in self?.previous() },
            onPhoto: { [weak self] in self?.pickPhoto() },
            onPalettePhoto: { [weak self] in self?.pickPalettePhoto() },
            onStill: { [weak self] in self?.exportStill(save: false) },
            onExport: { [weak self] in self?.exportStill(save: true) }
        )
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Pixeldish"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editor = w
    }

    func pickPhoto() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { wall.loadPhoto(u) }
    }

    // reuses loadPhoto's own downscale + the 5-stop bucket averager. luminance
    // is monotonic by construction (bucket i is strictly darker pixels than
    // bucket i+1); hue is whatever the photo has, same tradeoff hand-picked
    // palettes already accept
    func pickPalettePhoto() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let u = p.url,
              let ns = NSImage(contentsOf: u),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let pal = PhotoPalette.generate(from: cg)
        else { return }
        PhotoPalette.save(pal)
        Pref.d.set(kPalettes.count - 1, forKey: "palette")
        wall.refresh()
    }

    // exports every display, not just the first — same resolution isn't
    // guaranteed between monitors so each gets its own render and file
    func exportStill(save: Bool) {
        let base: URL
        if save {
            let sp = NSSavePanel()
            sp.nameFieldStringValue = "pixeldish.png"
            guard sp.runModal() == .OK, let u = sp.url else { return }
            base = u
        } else {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("pixeldish-still.png")
        }
        let multi = wall.renderers.count > 1
        var firstOut: URL?
        for (i, (r, v)) in zip(wall.renderers, wall.views).enumerated() {
            let w = Int(v.drawableSize.width), h = Int(v.drawableSize.height)
            guard let px = r.render(makeUniforms(w: w, h: h, time: 0), w: w, h: h),
                  let img = cgImage(px, w: w, h: h)
            else { continue }
            let out =
                multi
                    ? base.deletingLastPathComponent()
                    .appendingPathComponent(base.deletingPathExtension().lastPathComponent + "-\(i + 1)")
                    .appendingPathExtension(base.pathExtension) : base
            guard writePNG(img, to: out) else { continue }
            if firstOut == nil { firstOut = out }
        }
        if !save, let firstOut { NSWorkspace.shared.open(firstOut) }
    }
}
