#!/usr/bin/env swift

import AppKit
import Foundation

private let side = 1024

private func stroke(
    _ path: NSBezierPath,
    color: NSColor,
    width: CGFloat,
    glow: CGFloat = 0
) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    if glow > 0 {
        context.setShadow(
            offset: .zero,
            blur: glow,
            color: NSColor.white.withAlphaComponent(0.22).cgColor
        )
    }
    color.setStroke()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
    context.restoreGState()
}

private func drawNode(center: NSPoint) {
    let rect = NSRect(x: center.x - 91, y: center.y - 72, width: 182, height: 144)
    let path = NSBezierPath(roundedRect: rect, xRadius: 34, yRadius: 34)
    guard let context = NSGraphicsContext.current?.cgContext else { return }

    context.saveGState()
    context.setShadow(
        offset: .zero,
        blur: 24,
        color: NSColor.white.withAlphaComponent(0.16).cgColor
    )
    NSColor(calibratedWhite: 0.70, alpha: 1).setFill()
    path.fill()
    context.restoreGState()

    NSColor(calibratedWhite: 0.96, alpha: 1).setStroke()
    path.lineWidth = 7
    path.stroke()

    let highlight = NSBezierPath()
    highlight.move(to: NSPoint(x: rect.minX + 30, y: rect.maxY - 28))
    highlight.line(to: NSPoint(x: rect.maxX - 30, y: rect.maxY - 28))
    stroke(
        highlight,
        color: NSColor.white.withAlphaComponent(0.62),
        width: 5
    )
}

private func makeIcon() throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.noneSkipLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: side * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }

    graphics.imageInterpolation = .high
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)

    let bounds = NSRect(x: 0, y: 0, width: side, height: side)
    NSColor.black.setFill()
    bounds.fill()

    // A neutral lift keeps the mark legible at small sizes without adding hue.
    NSGradient(
        colors: [
            NSColor(calibratedWhite: 0.085, alpha: 1),
            NSColor(calibratedWhite: 0.015, alpha: 1),
        ]
    )?.draw(in: bounds.insetBy(dx: 40, dy: 40), relativeCenterPosition: .zero)

    let upperBranch = NSBezierPath()
    upperBranch.move(to: NSPoint(x: 520, y: 512))
    upperBranch.curve(
        to: NSPoint(x: 700, y: 676),
        controlPoint1: NSPoint(x: 630, y: 512),
        controlPoint2: NSPoint(x: 606, y: 676)
    )
    stroke(
        upperBranch,
        color: NSColor(calibratedWhite: 0.76, alpha: 1),
        width: 25,
        glow: 18
    )

    let lowerBranch = NSBezierPath()
    lowerBranch.move(to: NSPoint(x: 520, y: 512))
    lowerBranch.curve(
        to: NSPoint(x: 700, y: 348),
        controlPoint1: NSPoint(x: 630, y: 512),
        controlPoint2: NSPoint(x: 606, y: 348)
    )
    stroke(
        lowerBranch,
        color: NSColor(calibratedWhite: 0.76, alpha: 1),
        width: 25,
        glow: 18
    )

    drawNode(center: NSPoint(x: 790, y: 676))
    drawNode(center: NSPoint(x: 790, y: 348))

    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 225, y: 756))
    chevron.line(to: NSPoint(x: 448, y: 512))
    chevron.line(to: NSPoint(x: 225, y: 268))
    stroke(chevron, color: .white, width: 104, glow: 28)

    let cursor = NSBezierPath()
    cursor.move(to: NSPoint(x: 418, y: 270))
    cursor.line(to: NSPoint(x: 590, y: 270))
    stroke(cursor, color: .white, width: 76, glow: 24)

    guard let image = context.makeImage() else {
        throw CocoaError(.fileWriteUnknown)
    }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(
        using: .png,
        properties: [.compressionFactor: 1]
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

let outputPaths = CommandLine.arguments.dropFirst()
guard !outputPaths.isEmpty else {
    FileHandle.standardError.write(Data("usage: generate-app-icons.swift OUTPUT...\n".utf8))
    exit(64)
}

do {
    let data = try makeIcon()
    for path in outputPaths {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
} catch {
    FileHandle.standardError.write(Data("app icon generation failed: \(error)\n".utf8))
    exit(1)
}
