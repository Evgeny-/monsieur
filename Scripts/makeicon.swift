#!/usr/bin/env swift
// Renders Resources/AppIcon.icns. Run via `make icon`.
// Purely cosmetic, but a recognisable icon makes the app easy to find in the
// System Settings > Privacy & Security lists where you grant it permissions.
import AppKit
import Foundation

func render(_ px: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = px * 0.08
    let rect = NSRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: px * 0.22, yRadius: px * 0.22)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.30, blue: 0.92, alpha: 1),
        NSColor(calibratedRed: 0.16, green: 0.58, blue: 0.95, alpha: 1),
    ])!.draw(in: path, angle: -90)

    let cfg = NSImage.SymbolConfiguration(pointSize: px * 0.5, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let s = sym.size
        let box = NSRect(x: (px - s.width) / 2, y: (px - s.height) / 2,
                         width: s.width, height: s.height)
        NSColor.white.set()
        box.fill(using: .sourceOver)
        sym.draw(in: box, from: .zero, operation: .destinationIn, fraction: 1)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
try? fm.removeItem(at: iconset)
print("wrote Resources/AppIcon.icns")
