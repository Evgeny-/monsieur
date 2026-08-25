#!/usr/bin/env swift
// Renders Resources/AppIcon.icns. Run via `make icon`.
//
// A moustache drawn out of a sound wave: the name is the joke, and an icon that
// carries it is worth more than another generic waveform in a menu of generic
// waveforms. It also has to survive being 16 points wide, which rules out fine
// detail -- one bold silhouette is the whole design.
import AppKit
import Foundation

/// The waveform: seven rounded bars on a lit plate.
///
/// Drawn rather than taken from SF Symbols -- `waveform` is right there and is
/// what this used to use, but Apple's licence forbids system symbols in an app
/// icon or logo.
///
/// The rhythm is deliberately not a smooth hill. A symmetric arc reads as a
/// decoration; an uneven one reads as sound. It still has to survive 16 points
/// wide, which is why there are seven bars and not twenty.
let barHeights: [CGFloat] = [0.34, 0.66, 0.44, 1.00, 0.58, 0.82, 0.30]

func waveform(in rect: NSRect) -> [(NSBezierPath, CGFloat)] {
    let count = CGFloat(barHeights.count)
    // A little over half of each slot is bar, the rest is air.
    let slot = rect.width / count
    let width = slot * 0.58
    let radius = width / 2

    return barHeights.enumerated().map { index, height in
        let h = max(rect.height * height, width)
        let x = rect.minX + slot * (CGFloat(index) + 0.5) - width / 2
        let bar = NSRect(x: x, y: rect.midY - h / 2, width: width, height: h)
        // Outer bars sit back a touch: depth without adding another colour.
        let distance = abs(CGFloat(index) - (count - 1) / 2) / ((count - 1) / 2)
        return (NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius),
                1.0 - distance * 0.28)
    }
}

func render(_ px: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = px * 0.075
    let plate = NSRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    let rounded = NSBezierPath(roundedRect: plate,
                              xRadius: px * 0.225, yRadius: px * 0.225)

    // sRGB, not calibrated RGB: the calibrated space converts lighter on the
    // way into a deviceRGB bitmap, which turned a deep violet into pale lilac.
    NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.16, blue: 0.80, alpha: 1),
        NSColor(srgbRed: 0.15, green: 0.27, blue: 0.88, alpha: 1),
        NSColor(srgbRed: 0.05, green: 0.42, blue: 0.92, alpha: 1),
    ])!.draw(in: rounded, angle: -78)

    NSGraphicsContext.current?.saveGraphicsState()
    rounded.setClip()

    // A soft light from above left, so the plate is lit rather than flat.
    // A hairline along the top edge, the way a physical bevel catches light.
    let bevel = NSBezierPath(roundedRect: plate.insetBy(dx: px * 0.005, dy: px * 0.005),
                             xRadius: px * 0.222, yRadius: px * 0.222)
    bevel.lineWidth = max(1, px * 0.008)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.42),
                        NSColor.white.withAlphaComponent(0.0)])!
        .draw(in: bevel, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    let box = NSRect(x: plate.minX + plate.width * 0.17,
                     y: plate.minY + plate.height * 0.20,
                     width: plate.width * 0.66, height: plate.height * 0.60)
    for (bar, alpha) in waveform(in: box) {
        NSColor.white.withAlphaComponent(alpha).setFill()
        bar.fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)

if CommandLine.arguments.contains("--preview") {
    let out = root.appendingPathComponent("docs/icon-preview.png")
    try! fm.createDirectory(at: out.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
    try! render(512).write(to: out)
    print("wrote \(out.path)")
    exit(0)
}

let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o",
               root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
try? fm.removeItem(at: iconset)
print("wrote Resources/AppIcon.icns")
