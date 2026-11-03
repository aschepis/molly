#!/usr/bin/env swift
// Draws the Molly app icon: a rounded square with a two-tone gradient and an
// ECG-style waveform. Usage: swift scripts/render-icon.swift out.png [size]
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: render-icon.swift out.png [size]\n".utf8))
    exit(2)
}
let outputPath = arguments[1]
let size = arguments.count >= 3 ? (Int(arguments[2]) ?? 1024) : 1024
let s = CGFloat(size)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("cannot create bitmap\n".utf8))
    exit(1)
}

// macOS icons leave a transparent margin around the rounded square.
let inset = s * 0.08
let square = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
let radius = square.width * 0.225
let path = CGPath(roundedRect: square, cornerWidth: radius, cornerHeight: radius, transform: nil)

context.saveGState()
context.addPath(path)
context.clip()
let top = CGColor(red: 0.16, green: 0.47, blue: 0.84, alpha: 1)
let bottom = CGColor(red: 0.08, green: 0.16, blue: 0.36, alpha: 1)
let gradient = CGGradient(colorsSpace: colorSpace, colors: [top, bottom] as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
context.restoreGState()

// The waveform: flat baseline, a sharp heartbeat spike, flat again.
let baseline = s * 0.5
let points: [(CGFloat, CGFloat)] = [
    (0.14, 0.0), (0.32, 0.0), (0.38, 0.10), (0.44, -0.12), (0.50, 0.30),
    (0.56, -0.26), (0.61, 0.08), (0.66, 0.0), (0.86, 0.0),
]
let wave = CGMutablePath()
for (index, point) in points.enumerated() {
    let x = square.minX + point.0 * square.width
    let y = baseline + point.1 * s
    if index == 0 { wave.move(to: CGPoint(x: x, y: y)) } else { wave.addLine(to: CGPoint(x: x, y: y)) }
}
context.saveGState()
context.addPath(path)
context.clip()
context.setLineCap(.round)
context.setLineJoin(.round)
context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.18))
context.setLineWidth(s * 0.062)
context.translateBy(x: 0, y: -s * 0.012)
context.addPath(wave)
context.strokePath()
context.translateBy(x: 0, y: s * 0.012)
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.setLineWidth(s * 0.05)
context.addPath(wave)
context.strokePath()
context.restoreGState()

guard let image = context.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    FileHandle.standardError.write(Data("cannot write \(outputPath): \(error)\n".utf8))
    exit(1)
}
