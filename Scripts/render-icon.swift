#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: swift Scripts/render-icon.swift input.svg output.png\n", stderr)
    exit(2)
}

let size = 1024
let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let image = NSImage(contentsOf: inputURL),
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: size * 4,
        bitsPerPixel: 32
      ),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Unable to prepare icon renderer.\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
image.draw(
    in: NSRect(x: 0, y: 0, width: size, height: size),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

let corners = [(0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1)]
guard corners.allSatisfy({ bitmap.colorAt(x: $0.0, y: $0.1)?.alphaComponent == 0 }) else {
    fputs("Icon canvas corners must be transparent.\n", stderr)
    exit(1)
}

guard let pixels = bitmap.bitmapData else {
    fputs("Unable to inspect rendered icon.\n", stderr)
    exit(1)
}

var minX = size
var minY = size
var maxX = -1
var maxY = -1
for y in 0..<size {
    let row = pixels.advanced(by: y * bitmap.bytesPerRow)
    for x in 0..<size where row[x * 4 + 3] > 4 {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }
}

let occupiedWidth = maxX - minX + 1
let occupiedHeight = maxY - minY + 1
guard occupiedWidth >= 820, occupiedHeight >= 820 else {
    fputs("Icon artwork is too small for the macOS canvas.\n", stderr)
    exit(1)
}

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode icon PNG.\n", stderr)
    exit(1)
}

try png.write(to: outputURL, options: .atomic)
print("Rendered \(outputURL.path): alpha bounds \(occupiedWidth)x\(occupiedHeight) at \(minX),\(minY)")
