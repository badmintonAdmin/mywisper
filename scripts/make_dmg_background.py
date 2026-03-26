#!/usr/bin/env python3
"""Generate a DMG background image for mywisper installer."""
import sys
import os

bg_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build", "dmg_background")
os.makedirs(bg_dir, exist_ok=True)
bg_path = os.path.join(bg_dir, "background.png")

from AppKit import (
    NSImage, NSMakeSize, NSMakeRect, NSMakePoint,
    NSGradient, NSColor, NSBezierPath, NSFont,
    NSAttributedString, NSFontAttributeName, NSForegroundColorAttributeName,
    NSBitmapImageRep, NSBitmapImageFileTypePNG,
    NSLineCapStyleRound, NSLineJoinStyleRound,
)

width, height = 660, 400

image = NSImage.alloc().initWithSize_(NSMakeSize(width, height))
image.lockFocus()

# Dark gradient background
gradient = NSGradient.alloc().initWithStartingColor_endingColor_(
    NSColor.colorWithRed_green_blue_alpha_(0.08, 0.08, 0.12, 1.0),
    NSColor.colorWithRed_green_blue_alpha_(0.15, 0.15, 0.22, 1.0),
)
gradient.drawInRect_angle_(NSMakeRect(0, 0, width, height), 270)

# Arrow between app icon and Applications
arrowColor = NSColor.colorWithRed_green_blue_alpha_(0.45, 0.45, 0.55, 0.7)
arrowColor.setStroke()

path = NSBezierPath.bezierPath()
path.setLineWidth_(2.5)
path.setLineCapStyle_(NSLineCapStyleRound)
path.moveToPoint_(NSMakePoint(270, height / 2))
path.lineToPoint_(NSMakePoint(390, height / 2))
path.stroke()

# Arrowhead
head = NSBezierPath.bezierPath()
head.setLineWidth_(2.5)
head.setLineCapStyle_(NSLineCapStyleRound)
head.setLineJoinStyle_(NSLineJoinStyleRound)
head.moveToPoint_(NSMakePoint(378, height / 2 + 14))
head.lineToPoint_(NSMakePoint(395, height / 2))
head.lineToPoint_(NSMakePoint(378, height / 2 - 14))
head.stroke()

# Title
titleAttrs = {
    NSFontAttributeName: NSFont.boldSystemFontOfSize_(18),
    NSForegroundColorAttributeName: NSColor.colorWithRed_green_blue_alpha_(0.85, 0.85, 0.92, 1.0),
}
title = NSAttributedString.alloc().initWithString_attributes_("mywisper", titleAttrs)
titleSize = title.size()
title.drawAtPoint_(NSMakePoint((width - titleSize.width) / 2, height - 42))

# Hint text
hintAttrs = {
    NSFontAttributeName: NSFont.systemFontOfSize_(12),
    NSForegroundColorAttributeName: NSColor.colorWithRed_green_blue_alpha_(0.55, 0.55, 0.65, 0.9),
}
hint = NSAttributedString.alloc().initWithString_attributes_("Drag to Applications to install", hintAttrs)
hintSize = hint.size()
hint.drawAtPoint_(NSMakePoint((width - hintSize.width) / 2, 22))

image.unlockFocus()

# Save as PNG
tiffData = image.TIFFRepresentation()
bitmapRep = NSBitmapImageRep.imageRepWithData_(tiffData)
pngData = bitmapRep.representationUsingType_properties_(NSBitmapImageFileTypePNG, {})
pngData.writeToFile_atomically_(bg_path, True)
print(f"Background saved to {bg_path}")
