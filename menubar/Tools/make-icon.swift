#!/usr/bin/swift
// Renders the GitSync app icon as a 1024×1024 PNG.
//
// Usage: swift Tools/make-icon.swift [output.png]
//
// The artwork is full-bleed (no transparent squircle margins) on purpose:
// macOS 26 masks legacy .icns icons into the rounded-rect shape itself,
// and icons that don't fill the canvas get shrunk onto a plain tile
// instead. The glyph matches the menu bar's arrow.triangle.2.circlepath
// so the app is recognizable across both.
//
// Regenerate Resources/AppIcon.icns after editing:
//   swift Tools/make-icon.swift /tmp/icon.png
//   then run the sips/iconutil steps in Tools/make-icns.sh

import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let canvas = 1024

func makeRep(pixelsWide: Int, pixelsHigh: Int, pointSize: NSSize) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not allocate bitmap") }
    rep.size = pointSize
    return rep
}

// --- Rasterize the SF Symbol, tinted white, into its own bitmap first.
// (Tinting with .sourceAtop inside the main canvas would bleach the
// gradient underneath the glyph's bounding box.)
let config = NSImage.SymbolConfiguration(pointSize: 460, weight: .semibold)
guard let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                           accessibilityDescription: nil)?
    .withSymbolConfiguration(config) else { fatalError("SF Symbol unavailable") }

let maxGlyphW: CGFloat = 660, maxGlyphH: CGFloat = 600
let scale = min(maxGlyphW / symbol.size.width, maxGlyphH / symbol.size.height)
let glyphW = (symbol.size.width * scale).rounded()
let glyphH = (symbol.size.height * scale).rounded()

let glyphRep = makeRep(pixelsWide: Int(glyphW), pixelsHigh: Int(glyphH),
                       pointSize: NSSize(width: glyphW, height: glyphH))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: glyphRep)
let glyphBounds = NSRect(x: 0, y: 0, width: glyphW, height: glyphH)
symbol.draw(in: glyphBounds, from: .zero, operation: .sourceOver, fraction: 1)
NSColor.white.set()
glyphBounds.fill(using: .sourceAtop)
NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

let glyph = NSImage(size: glyphBounds.size)
glyph.addRepresentation(glyphRep)

// --- Main canvas.
let rep = makeRep(pixelsWide: canvas, pixelsHigh: canvas,
                  pointSize: NSSize(width: canvas, height: canvas))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let full = NSRect(x: 0, y: 0, width: canvas, height: canvas)

// Vertical gradient, lit from the top: azure → deep blue.
let top    = NSColor(calibratedRed: 0.31, green: 0.62, blue: 1.00, alpha: 1)
let bottom = NSColor(calibratedRed: 0.03, green: 0.22, blue: 0.55, alpha: 1)
NSGradient(starting: bottom, ending: top)!.draw(in: full, angle: 90)

// Soft radial highlight near the top, the usual "overhead light" touch.
let glowCenter = NSPoint(x: 512, y: 900)
NSGradient(starting: NSColor.white.withAlphaComponent(0.18),
           ending: NSColor.white.withAlphaComponent(0.0))!
    .draw(fromCenter: glowCenter, radius: 0,
          toCenter: glowCenter, radius: 640,
          options: .drawsBeforeStartingLocation)

// Glyph, centered, with a soft drop shadow for depth.
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()

let glyphRect = NSRect(x: (CGFloat(canvas) - glyphW) / 2,
                       y: (CGFloat(canvas) - glyphH) / 2,
                       width: glyphW, height: glyphH)
glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)

NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG encode failed")
}
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
