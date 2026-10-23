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
    var syncWork: DispatchWorkItem?
    var lastSync = ""
    var ticks = 0
    var lastStill = Date()

    func applicationDidFinishLaunching(_ n: Notification) {
        Pref.register()
        Config.load()
        history = (Pref.d.array(forKey: "history") as? [[String: Any]]) ?? []
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        installSaver()
        wall.rebuild()
        scheduleDesktopSync()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.wall.rebuild()
            self?.lastSync = ""
            self?.scheduleDesktopSync()
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
            // ponytail: polls both config files every 2s; a stat is cheaper than watching a symlink chain nix swaps
            ticks += 1
            if ticks % 40 == 0 { Config.poll() }
            // ponytail: the system wallpaper (menu bar tint, Mission Control, lock screen) follows
            // the animation once a minute; finer means a full-screen PNG write every few seconds.
            // wall clock, not ticks: macOS throttles the timer when the app is napped
            if live, Date().timeIntervalSince(lastStill) > 60 {
                lastSync = ""
                syncDesktop()
            }
        }
        wall.setPaused(!Pref.d.bool(forKey: "animate"))
        wall.refresh()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if !live { wall.refresh() }
            scheduleDesktopSync()
        }
    }

    // Low Power Mode holds the current frame; settings still redraw it
    var live: Bool { Pref.d.bool(forKey: "animate") && !ProcessInfo.processInfo.isLowPowerModeEnabled }

    func buildStatusItem() {
        let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        s.button?.image = steakIcon()
        let m = NSMenu()
        m.addItem(withTitle: "Editor", action: #selector(openEditor), keyEquivalent: "e")
        m.addItem(withTitle: "Shuffle", action: #selector(shuffle), keyEquivalent: "r")
        m.addItem(withTitle: "Previous", action: #selector(previous), keyEquivalent: "p")
        m.addItem(withTitle: "Save look", action: #selector(saveLook), keyEquivalent: "s")
        m.addItem(withTitle: "Copy pattern", action: #selector(copyPattern), keyEquivalent: "c")
        m.addItem(withTitle: "Paste pattern", action: #selector(pastePattern), keyEquivalent: "v")
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

    func pushHistory() {
        history.append(currentPattern())
        if history.count > 24 { history.removeFirst() }
        Pref.d.set(history, forKey: "history")
    }

    @objc func shuffle() {
        lastShuffle = Date()
        pushHistory()
        let d = Pref.d
        let shape = Int.random(in: 0 ..< kShapeNames.count)
        d.set(shape, forKey: "shape")
        for p in shapeParams(shape) {
            d.set(Double.random(in: p.range), forKey: paramKey(shape, p))
        }
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

    // ponytail: saved looks are a flat list with auto names, no thumbnails or
    // rename (the config file takes a name); add a gallery if the list gets long
    @objc func saveLook() {
        var look = currentPattern()
        let df = DateFormatter()
        df.dateFormat = "MMM d HH:mm"
        look["name"] = "\(look["shape"] ?? "?") / \(look["palette"] ?? "?") / \(df.string(from: Date()))"
        storeLooks([look] + savedLooks().filter { $0["id"] as? String != look["id"] as? String })
    }

    // one line of KYAML: paste it into a chat, another Pixeldish, or nix-darwin
    @objc func copyPattern() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(KYAML.emit(currentPattern(), line: true), forType: .string)
    }

    // takes a pattern, or the id of a saved one
    @objc func pastePattern() {
        guard let s = NSPasteboard.general.string(forType: .string),
              let v = try? KYAML.parse(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let p = Config.resolve(v, savedLooks())
        else { NSSound.beep()
            return
        }
        pushHistory()
        applyPattern(p)
        wall.reset()
        wall.refresh()
    }

    func loadSaved(_ i: Int) {
        let s = savedLooks()
        guard s.indices.contains(i) else { return }
        pushHistory()
        applyPattern(s[i])
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
        applyPattern(last)
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
            onCopy: { [weak self] in self?.copyPattern() },
            onPaste: { [weak self] in self?.pastePattern() },
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
            guard let px = r.render(makeUniforms(w: w, h: h, time: r.now), w: w, h: h),
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

extension AppDelegate {
    // the system wallpaper is what Mission Control, the lock screen and a quit
    // app show, so it gets a still of the current look. Sliders write defaults
    // every tick, hence the debounce
    func scheduleDesktopSync() {
        syncWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.syncDesktop() }
        syncWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    func syncDesktop() {
        Config.save()
        let photo = wall.renderers.first?.photo.map { "\(ObjectIdentifier($0 as AnyObject))" } ?? ""
        let key = "\(makeUniforms(w: 1, h: 1, time: 0))\(photo)"
        guard key != lastSync,
              let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
              .appendingPathComponent("Pixeldish")
        else { return }
        lastSync = key
        lastStill = Date()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // the wallpaper store ignores a URL it already shows, so alternate two names per display
        let slot = Pref.d.bool(forKey: "desktopSlot")
        Pref.d.set(!slot, forKey: "desktopSlot")
        for (screen, (r, v)) in zip(wall.screens, zip(wall.renderers, wall.views)) {
            let w = Int(v.drawableSize.width), h = Int(v.drawableSize.height)
            let sw = Int(screen.frame.width * screen.backingScaleFactor)
            let sh = Int(screen.frame.height * screen.backingScaleFactor)
            // the window is oversized past the screen edges, crop back to what is visible
            guard w >= sw, h >= sh,
                  let px = r.render(makeUniforms(w: w, h: h, time: r.now), w: w, h: h),
                  let img = cgImage(px, w: w, h: h)?
                  .cropping(to: CGRect(x: (w - sw) / 2, y: (h - sh) / 2, width: sw, height: sh))
            else { continue }
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int ?? 0
            let url = dir.appendingPathComponent("desktop-\(id)-\(slot ? "a" : "b").png")
            guard writePNG(img, to: url) else { continue }
            // ponytail: only the current Space per display; other Spaces catch up on a later sync
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
    }

    // the screen saver ships inside the app and is copied over whenever the
    // bundled build differs, so updating the app updates the saver too
    func installSaver() {
        guard let src = Bundle.main.url(forResource: "Pixeldish", withExtension: "saver") else { return }
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers")
        let dst = dir.appendingPathComponent("Pixeldish.saver")
        let bin = "Contents/MacOS/PixeldishSaver"
        if fm.contentsEqual(
            atPath: src.appendingPathComponent(bin).path,
            andPath: dst.appendingPathComponent(bin).path
        ) {
            return
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: dst)
        try? fm.copyItem(at: src, to: dst)
        // copyItem keeps the quarantine a brew/dmg install put on the app, and
        // the screen saver host won't load a quarantined ad-hoc bundle. A copy
        // out of the nix store is read-only, which would block the next update
        let paths = [dst.path] + (fm.subpaths(atPath: dst.path) ?? []).map { dst.path + "/" + $0 }
        for p in paths {
            removexattr(p, "com.apple.quarantine", XATTR_NOFOLLOW)
            var st = stat()
            if lstat(p, &st) == 0 { chmod(p, st.st_mode | S_IWUSR) }
        }
    }
}

// a seared steak on a plate, one point per pixel. In colour, not a template:
// a monochrome steak reads as bread, a mirror or an eye. The grey rim keeps
// the white plate visible on a light menu bar
let kSteak = [
    ".......gggggg.......",
    "....ggwwwwwwwwgg....",
    "..ggwwwwwwwwwwwwgg..",
    ".ggwwwffffffffwwwgg.",
    ".gwwffrrdrrrdrffwwg.",
    "ggwfrrrdrrrdrrrrfwgg",
    "gwwfrrdrrrdrrrdrowwg",
    "gwwfrdrrrdrrrdrrowwg",
    "ggwwfrrrdrrrdrroowgg",
    ".gwwwoorrrdrrooowwg.",
    ".ggwwwwooooooowwwgg.",
    "..ggwwwwwwwwwwwwgg..",
    "....ggwwwwwwwwgg....",
    ".......gggggg......."
]

let kSteakInk: [Character: NSColor] = [
    "g": NSColor(srgbRed: 0.62, green: 0.64, blue: 0.68, alpha: 1), // plate rim
    "w": NSColor(srgbRed: 0.96, green: 0.96, blue: 0.95, alpha: 1), // plate
    "f": NSColor(srgbRed: 0.97, green: 0.86, blue: 0.70, alpha: 1), // fat
    "r": NSColor(srgbRed: 0.72, green: 0.25, blue: 0.18, alpha: 1), // meat
    "d": NSColor(srgbRed: 0.33, green: 0.12, blue: 0.08, alpha: 1), // grill marks
    "o": NSColor(srgbRed: 0.48, green: 0.15, blue: 0.10, alpha: 1) // seared edge
]

func steakIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: kSteak[0].count, height: kSteak.count), flipped: true) { _ in
        for (y, row) in kSteak.enumerated() {
            for (x, c) in row.enumerated() {
                guard let ink = kSteakInk[c] else { continue }
                ink.setFill()
                NSRect(x: x, y: y, width: 1, height: 1).fill()
            }
        }
        return true
    }
    img.accessibilityDescription = "Pixeldish"
    return img
}
