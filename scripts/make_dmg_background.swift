#!/usr/bin/env swift
import AppKit

// Oversized to ensure full coverage of Finder window content area
let width: CGFloat = 660
let height: CGFloat = 480
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSString(string: "~").expandingTildeInPath + "/Downloads/dmg_background.png"

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

// Light solid background (no gradient — clean look)
NSColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1.0).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

// Arrow between icon positions (app at x=130, Applications at x=390)
// Finder icon y=170 from top → from bottom = height - 170 = 310
let arrowY: CGFloat = height - 170
let arrowColor = NSColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 0.45)
arrowColor.setStroke()

let shaft = NSBezierPath()
shaft.lineWidth = 1.5
shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: 205, y: arrowY))
shaft.line(to: NSPoint(x: 315, y: arrowY))
shaft.stroke()

// Arrowhead
let head = NSBezierPath()
head.lineWidth = 1.5
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.move(to: NSPoint(x: 305, y: arrowY + 10))
head.line(to: NSPoint(x: 320, y: arrowY))
head.line(to: NSPoint(x: 305, y: arrowY - 10))
head.stroke()

// Hint text at bottom
let hintAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11),
    .foregroundColor: NSColor(red: 0.45, green: 0.45, blue: 0.50, alpha: 0.7),
]
let hint = NSAttributedString(string: "Drag to Applications to install", attributes: hintAttrs)
let hintSize = hint.size()
hint.draw(at: NSPoint(x: (width / 2 - hintSize.width / 2) - 20, y: height - 310))

image.unlockFocus()

// Save as PNG
guard let tiffData = image.tiffRepresentation,
      let bitmapRep = NSBitmapImageRep(data: tiffData),
      let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    print("Failed to create PNG")
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
try! pngData.write(to: url)
print("Background saved to \(outputPath)")
