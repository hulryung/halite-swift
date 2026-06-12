#!/usr/bin/env swift
// gen-og.swift — generates assets/og.png (1200×630, Open Graph image).
//
// Places Resources/Damson-1024.png (the app icon) on the left and composites
// the product name/tagline on the right via AppKit. No external dependencies.
//
// build: swift scripts/gen-og.swift

import AppKit

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let iconURL = repoRoot.appendingPathComponent("Resources/Damson-1024.png")
let outURL = repoRoot.appendingPathComponent("assets/og.png")

let W = 1200, H = 630
let bg = NSColor(srgbRed: 0x1a / 255.0, green: 0x1b / 255.0, blue: 0x26 / 255.0, alpha: 1)

guard let icon = NSImage(contentsOf: iconURL) else {
    fatalError("icon not found: \(iconURL.path)")
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

bg.setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

// The icon PNG's corners (outside the rounded rect) are white, so clip with a rounded path.
let iconRect = NSRect(x: 48, y: 43, width: 544, height: 544)
let cornerRadius = 180.0 / 1024.0 * iconRect.width
NSGraphicsContext.current?.saveGraphicsState()
NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
icon.draw(in: iconRect)
NSGraphicsContext.current?.restoreGraphicsState()

func draw(_ text: String, x: CGFloat, y: CGFloat, font: NSFont, hex: UInt32) {
    let color = NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255.0,
        green: CGFloat((hex >> 8) & 0xff) / 255.0,
        blue: CGFloat(hex & 0xff) / 255.0, alpha: 1)
    (text as NSString).draw(
        at: NSPoint(x: x, y: y),
        withAttributes: [.font: font, .foregroundColor: color])
}

let title = NSFont(name: "HelveticaNeue-Bold", size: 100)!
let tagline = NSFont(name: "HelveticaNeue-Medium", size: 33)!
let body = NSFont(name: "HelveticaNeue", size: 28)!
let mono = NSFont(name: "Menlo-Regular", size: 28)!

draw("Damson", x: 612, y: 372, font: title, hex: 0xffffff)
draw("The terminal built only for macOS", x: 620, y: 296, font: tagline, hex: 0xab88e6)
draw("Buttery 120 Hz scrolling · flawless 한글 input", x: 622, y: 218, font: body, hex: 0x9aa5ce)
draw("Metal GPU rendering · tabs & split panes", x: 622, y: 176, font: body, hex: 0x9aa5ce)
draw("❯", x: 622, y: 92, font: mono, hex: 0x9ece6a)
draw("damson.app", x: 660, y: 92, font: mono, hex: 0xc0caf5)

NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! FileManager.default.createDirectory(
    at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try! png.write(to: outURL)
print("==> \(outURL.path) (\(W)x\(H))")
