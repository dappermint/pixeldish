import AppKit

// pixeldish: dithered procedural wallpapers.
// One borderless window per screen sits below the desktop icons and draws with Metal.

// the CLI modes below run before AppKit starts, so none of them opens a window.
// --capture <path> [w h] renders the current settings offscreen; the display is the
// thing being tested, so this must not need screen recording
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--capture") {
    Pref.register()
    let path = args.count > i + 1 ? args[i + 1] : "/tmp/pixeldish.png"
    let w = args.count > i + 3 ? Int(args[i + 2]) ?? 3_600 : 3_600
    let h = args.count > i + 3 ? Int(args[i + 3]) ?? 2_338 : 2_338
    let ok =
        DishRenderer(shader: kShaderPath)?.render(makeUniforms(w: w, h: h, time: 12.5), w: w, h: h)
            .flatMap { cgImage($0, w: w, h: h) }
            .map { writePNG($0, to: URL(fileURLWithPath: path)) } ?? false
    print(ok ? "captured \(path) \(w)x\(h)" : "capture failed")
    exit(ok ? 0 : 1)
}

// --sheet <path>: every shape x dither in one PNG, to judge the audit's numbers by eye
if let i = args.firstIndex(of: "--sheet") {
    let path = args.count > i + 1 ? args[i + 1] : "contact-sheet.png"
    let w = 160, h = 110, cols = kShapeNames.count, rows = kDitherNames.count
    guard let r = DishRenderer(shader: kShaderPath),
          let sheet = CGContext(
              data: nil, width: w * cols, height: h * rows, bitsPerComponent: 8,
              bytesPerRow: w * cols * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { print("sheet failed")
        exit(1)
    }
    for shape in 0 ..< cols {
        for dither in 0 ..< rows {
            guard let px = r.render(comboUniforms(shape, dither, w: w, h: h), w: w, h: h),
                  let img = cgImage(px, w: w, h: h)
            else { continue }
            sheet.draw(img, in: CGRect(x: shape * w, y: (rows - 1 - dither) * h, width: w, height: h))
        }
    }
    let ok = sheet.makeImage().map { writePNG($0, to: URL(fileURLWithPath: path)) } ?? false
    print(ok ? "wrote \(path) (\(cols) shapes x \(rows) dithers)" : "sheet failed")
    exit(ok ? 0 : 1)
}

#if AUDIT
// no Pref.register: a saved Custom palette is the user's data, not a shipped palette to gate on
if args.contains("--audit") { exit(runAudit() ? 0 : 1) }
#endif
if args.contains("--selftest") { exit(runSelftest() ? 0 : 1) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
