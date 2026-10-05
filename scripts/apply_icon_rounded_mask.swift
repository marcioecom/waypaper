#!/usr/bin/env swift
import AppKit
import Foundation

private let cornerRadiusFraction: CGFloat = 224.0 / 1024.0

let args = CommandLine.arguments
if args.count < 3 {
    fputs("Usage: apply_icon_rounded_mask.swift <input.png> <output.png> [dimension]\n", stderr)
    exit(2)
}
let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])
let dimension = args.count >= 4 ? CGFloat(Int(args[3]) ?? 1024) : 1024

guard let source = NSImage(contentsOf: inputURL),
      let sourceTIFF = source.tiffRepresentation,
      let sourceBitmap = NSBitmapImageRep(data: sourceTIFF)
else {
    fputs("Failed to load input image\n", stderr)
    exit(1)
}

let pixelsWide = Int(dimension)
let pixelsHigh = Int(dimension)
guard let outputBitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelsWide,
    pixelsHigh: pixelsHigh,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Failed to allocate output bitmap\n", stderr)
    exit(1)
}

outputBitmap.size = NSSize(width: dimension, height: dimension)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: outputBitmap)

NSColor.clear.set()
NSRect(x: 0, y: 0, width: dimension, height: dimension).fill()

let radius = dimension * cornerRadiusFraction
let clip = NSBezierPath(
    roundedRect: NSRect(x: 0, y: 0, width: dimension, height: dimension),
    xRadius: radius,
    yRadius: radius
)
clip.addClip()

let drawRect = NSRect(x: 0, y: 0, width: dimension, height: dimension)
let fromRect = NSRect(x: 0, y: 0, width: sourceBitmap.pixelsWide, height: sourceBitmap.pixelsHigh)
source.draw(
    in: drawRect,
    from: fromRect,
    operation: .copy,
    fraction: 1.0,
    respectFlipped: false,
    hints: nil
)

NSGraphicsContext.restoreGraphicsState()

guard let png = outputBitmap.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}

do {
    try png.write(to: outputURL)
} catch {
    fputs("Failed to write output: \(error)\n", stderr)
    exit(1)
}
