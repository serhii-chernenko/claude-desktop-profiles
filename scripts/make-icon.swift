import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make-icon.swift OUTPUT.png\n", stderr)
    exit(2)
}

let canvasSide = 1024
let contentInset: CGFloat = 104
let tileSide: CGFloat = 588
let cornerRadiusRatio: CGFloat = 0.225
let shadeAlpha: CGFloat = 0.08

struct Tile {
    let rect: CGRect
    let color: NSColor
    let glyphRotation: CGFloat
    let glyphShift: CGPoint
}

struct Ray {
    let angle: CGFloat
    let length: CGFloat
    let width: CGFloat
}

func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: alpha
    )
}

let rays: [Ray] = [
    Ray(angle: 3, length: 1.00, width: 0.70),
    Ray(angle: 31, length: 0.66, width: 1.00),
    Ray(angle: 58, length: 0.94, width: 0.86),
    Ray(angle: 92, length: 0.62, width: 0.92),
    Ray(angle: 119, length: 0.90, width: 0.74),
    Ray(angle: 148, length: 0.72, width: 1.00),
    Ray(angle: 177, length: 1.00, width: 0.72),
    Ray(angle: 207, length: 0.64, width: 0.96),
    Ray(angle: 235, length: 0.92, width: 0.80),
    Ray(angle: 266, length: 0.68, width: 1.00),
    Ray(angle: 294, length: 0.98, width: 0.74),
    Ray(angle: 324, length: 0.70, width: 0.94),
]

let glyphReach: CGFloat = 0.39
let glyphRayWidth: CGFloat = 0.078
let glyphCornerRadius: CGFloat = 0.014

func rayPath(_ ray: Ray, reach: CGFloat, rayWidth: CGFloat, cornerRadius: CGFloat) -> CGPath {
    let length = reach * ray.length
    let halfBase = rayWidth * ray.width * 0.20 - cornerRadius
    let halfMiddle = rayWidth * ray.width * 0.5 - cornerRadius
    let halfEnd = rayWidth * ray.width * 0.46 - cornerRadius
    let inner = cornerRadius
    let outer = length - cornerRadius
    let path = CGMutablePath()
    path.move(to: CGPoint(x: inner, y: -halfBase))
    path.addLine(to: CGPoint(x: outer * 0.5, y: -halfMiddle))
    path.addLine(to: CGPoint(x: outer, y: -halfEnd))
    path.addLine(to: CGPoint(x: outer - rayWidth * 0.05, y: halfEnd * 0.82))
    path.addLine(to: CGPoint(x: outer * 0.5, y: halfMiddle))
    path.addLine(to: CGPoint(x: inner, y: halfBase))
    path.closeSubpath()
    let radians = ray.angle * .pi / 180
    var transform = CGAffineTransform(rotationAngle: radians)
    return path.copy(using: &transform) ?? path
}

func drawGlyph(in context: CGContext, center: CGPoint, scale: CGFloat, rotation: CGFloat) {
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: rotation * .pi / 180)
    context.scaleBy(x: scale, y: scale)
    let shapes = CGMutablePath()
    for ray in rays {
        shapes.addPath(rayPath(ray, reach: glyphReach, rayWidth: glyphRayWidth, cornerRadius: glyphCornerRadius))
    }
    let hub = glyphRayWidth * 0.70
    let strokeWidth = glyphCornerRadius * 2

    func paint(shadowed: Bool) {
        context.saveGState()
        if shadowed {
            context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.2).cgColor)
        }
        context.setFillColor(NSColor.white.withAlphaComponent(0.97).cgColor)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.97).cgColor)
        context.setLineJoin(.round)
        context.setLineWidth(strokeWidth)
        context.addPath(shapes)
        context.drawPath(using: .fillStroke)
        context.fillEllipse(in: CGRect(x: -hub, y: -hub, width: hub * 2, height: hub * 2))
        context.restoreGState()
    }

    paint(shadowed: true)
    paint(shadowed: false)
    context.restoreGState()
}

func tilePath(_ rect: CGRect) -> CGPath {
    let radius = rect.width * cornerRadiusRatio
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawTile(_ tile: Tile, in context: CGContext, castingShadow: Bool) {
    let path = tilePath(tile.rect)
    if castingShadow {
        context.saveGState()
        context.setShadow(offset: CGSize(width: -10, height: -16), blur: 34, color: NSColor.black.withAlphaComponent(0.42).cgColor)
        context.setFillColor(tile.color.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    context.saveGState()
    context.addPath(path)
    context.clip()
    context.setFillColor(tile.color.cgColor)
    context.fill(tile.rect)
    let shade = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor.black.withAlphaComponent(shadeAlpha).cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        shade,
        start: CGPoint(x: tile.rect.midX, y: tile.rect.minY),
        end: CGPoint(x: tile.rect.midX, y: tile.rect.maxY),
        options: []
    )
    drawGlyph(
        in: context,
        center: CGPoint(x: tile.rect.midX + tile.glyphShift.x * tile.rect.width, y: tile.rect.midY + tile.glyphShift.y * tile.rect.width),
        scale: tile.rect.width,
        rotation: tile.glyphRotation
    )
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()
}

let span = CGFloat(canvasSide) - contentInset * 2
let frontOrigin = CGPoint(x: contentInset + span - tileSide, y: contentInset)
let backOrigin = CGPoint(x: contentInset, y: contentInset + span - tileSide)
let back = Tile(
    rect: CGRect(origin: backOrigin, size: CGSize(width: tileSide, height: tileSide)),
    color: srgb(0xE30E7C),
    glyphRotation: 14,
    glyphShift: CGPoint(x: -0.05, y: 0.05)
)
let front = Tile(
    rect: CGRect(origin: frontOrigin, size: CGSize(width: tileSide, height: tileSide)),
    color: srgb(0xD9704E),
    glyphRotation: 0,
    glyphShift: .zero
)

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasSide,
    pixelsHigh: canvasSide,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create the icon canvas\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let context = graphics.cgContext
context.interpolationQuality = .high
drawTile(back, in: context, castingShadow: false)
drawTile(front, in: context, castingShadow: true)
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not render icon\n", stderr)
    exit(1)
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
