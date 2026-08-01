#!/usr/bin/swift
// Generate assets/AppIcon-1024.png: a macOS-style rounded square with a
// zipper down the middle and transfer arrows — the mac↔Windows round-trip.
// Usage: swift scripts/gen-icon.swift assets/AppIcon-1024.png
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

let size = 1024
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: gen-icon.swift <output.png>\n".utf8))
    exit(64)
}
let outputPath = CommandLine.arguments[1]

let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Apple icon grid: content square inset ~100 px on a 1024 canvas,
// corner radius ~185.
let margin: CGFloat = 100
let plate = CGRect(x: margin, y: margin,
                   width: CGFloat(size) - margin * 2, height: CGFloat(size) - margin * 2)
let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Background: deep blue gradient.
ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [rgba(43, 116, 216), rgba(18, 55, 128)] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: plate.midX, y: plate.maxY),
    end: CGPoint(x: plate.midX, y: plate.minY),
    options: [])

// Zipper: two columns of interlocking teeth down the center.
let center = plate.midX
let toothW: CGFloat = 84
let toothH: CGFloat = 52
let zipTop = plate.maxY - 120
let zipBottom = plate.minY + 260
ctx.setFillColor(rgba(255, 255, 255, 0.92))
var y = zipTop
var left = true
while y > zipBottom {
    // Interlocking: each tooth reaches just past the center line, and
    // successive teeth overlap vertically by half a tooth.
    let x = left ? center - toothW + 6 : center - 6
    ctx.fill(CGRect(x: x, y: y - toothH, width: toothW, height: toothH))
    y -= toothH * 0.62
    left.toggle()
}

// Zipper pull below the teeth.
ctx.setFillColor(rgba(255, 255, 255, 0.92))
let pullTop = zipBottom - 8
ctx.fill(CGRect(x: center - 22, y: pullTop - 60, width: 44, height: 60))
let ringRect = CGRect(x: center - 52, y: pullTop - 176, width: 104, height: 120)
ctx.setStrokeColor(rgba(255, 255, 255, 0.92))
ctx.setLineWidth(34)
ctx.strokeEllipse(in: ringRect.insetBy(dx: 17, dy: 17))

// Transfer arrows: left (mac side) and right (Windows side).
func arrow(atX x: CGFloat, pointingRight: Bool) {
    let yMid = plate.midY + 40
    let shaft: CGFloat = 120
    let head: CGFloat = 56
    let path = CGMutablePath()
    let direction: CGFloat = pointingRight ? 1 : -1
    path.move(to: CGPoint(x: x - direction * shaft / 2, y: yMid))
    path.addLine(to: CGPoint(x: x + direction * shaft / 2, y: yMid))
    path.move(to: CGPoint(x: x + direction * (shaft / 2 - head), y: yMid + head))
    path.addLine(to: CGPoint(x: x + direction * shaft / 2, y: yMid))
    path.addLine(to: CGPoint(x: x + direction * (shaft / 2 - head), y: yMid - head))
    ctx.addPath(path)
    ctx.setStrokeColor(rgba(255, 255, 255, 0.55))
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}
arrow(atX: center - 210, pointingRight: false)
arrow(atX: center + 210, pointingRight: true)
ctx.restoreGState()

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("failed to write \(outputPath)\n".utf8))
    exit(1)
}
print("wrote \(outputPath)")
