// Renders the app icon — a full-bleed camera lens (deliberately distinct from
// Apple's Camera icon: blue glass, dark barrel, blue accent ring on a bright
// blue field) — and packs it into an .icns. Detail is tiered by output size.
// Usage: swift tools/make_icon.swift Resources/AppIcon.icns
import AppKit

func drawIcon(size n: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let t = NSAffineTransform()
    t.scale(by: CGFloat(n) / 1024.0)
    t.concat()

    let detailed = n >= 128
    let medium = n >= 64

    func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }
    func circle(_ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: 512 - r, y: 512 - r, width: 2 * r, height: 2 * r))
    }

    // Rounded-square background
    let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 1024, height: 1024),
                          xRadius: 228, yRadius: 228)
    NSGradient(starting: c(0x8fc4f4), ending: c(0x4a7ed2))!.draw(in: bg, angle: -90)

    // Barrel — bigger at tiny sizes so the lens IS the icon
    let barrelR: CGFloat = medium ? 400 : 440
    c(0x262b31).setFill()
    circle(barrelR).fill()
    if medium {
        NSGradient(starting: c(0x4a505a), ending: c(0x20242a))!.draw(in: circle(382), angle: -90)
        c(0x101318).setFill()
        circle(350).fill()
    }
    if detailed {
        // Accent ring between barrel and glass
        c(0x5b9be0, 0.8).setStroke()
        let accent = circle(338)
        accent.lineWidth = 7
        accent.stroke()
    }

    // Outer glass
    let glassR: CGFloat = medium ? 330 : 390
    NSGradient(colors: [c(0x6fa8e8), c(0x274d8c), c(0x101f3d)])!
        .draw(in: circle(glassR), relativeCenterPosition: NSPoint(x: -0.2, y: 0.25))

    if detailed {
        c(0xffffff, 0.12).setStroke()
        let ring = circle(210)
        ring.lineWidth = 6
        ring.stroke()
    }

    // Inner element
    if medium {
        NSGradient(colors: [c(0x3b6bb4), c(0x16294f), c(0x0a1730)])!
            .draw(in: circle(190), relativeCenterPosition: NSPoint(x: -0.25, y: 0.3))
    }

    // Pupil
    let pupilR: CGFloat = medium ? 95 : 130
    c(0x05070c).setFill()
    circle(pupilR).fill()
    if detailed {
        c(0x0d1b33).setFill()
        circle(60).fill()
    }

    // Reflections
    if medium {
        c(0xffffff, 0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: 240, y: 640, width: 220, height: 130)).fill()
        c(0xffffff, 0.40).setFill()
        NSBezierPath(ovalIn: NSRect(x: 672, y: 632, width: 56, height: 56)).fill()
        if detailed {
            c(0xffffff, 0.25).setFill()
            NSBezierPath(ovalIn: NSRect(x: 728, y: 596, width: 24, height: 24)).fill()
        }
    } else {
        c(0xffffff, 0.5).setFill()
        NSBezierPath(ovalIn: NSRect(x: 280, y: 620, width: 180, height: 120)).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(px: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("gopro-icon-\(UUID().uuidString)/AppIcon.iconset")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
for s in sizes {
    try drawIcon(size: s.px).write(to: tmp.appendingPathComponent("\(s.name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", out]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed")
exit(p.terminationStatus)
