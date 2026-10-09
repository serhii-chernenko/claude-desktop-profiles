import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make-icon.swift OUTPUT.png\n", stderr)
    exit(2)
}

let canvasSide: CGFloat = 1024
let bodySide: CGFloat = 824
let bodyCornerRadius: CGFloat = 215
let tileSide: CGFloat = 494
let tileSpan: CGFloat = 700
let tileCornerRadius = bodyCornerRadius * tileSide / bodySide
let bottomSaturationBoost: CGFloat = 1.12
let bottomLumaRatio: CGFloat = 0.92
let sheenAlpha: CGFloat = 0.12

struct Tile {
    let rect: CGRect
    let topColor: NSColor
    let glyphRotation: CGFloat
    let glyphShift: CGPoint
    let glyphScale: CGFloat
}

struct Ray {
    let angle: CGFloat
    let length: CGFloat
    let width: CGFloat
}

func srgb(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: 1
    )
}

func bottomColor(for top: NSColor) -> NSColor {
    let red = top.redComponent * bottomLumaRatio
    let green = top.greenComponent * bottomLumaRatio
    let blue = top.blueComponent * bottomLumaRatio
    let gray = 0.2126 * red + 0.7152 * green + 0.0722 * blue
    func saturate(_ channel: CGFloat) -> CGFloat {
        min(1, max(0, gray + (channel - gray) * bottomSaturationBoost))
    }
    return NSColor(srgbRed: saturate(red), green: saturate(green), blue: saturate(blue), alpha: 1)
}

func squirclePath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    typealias Step = (c1: CGPoint, c2: CGPoint, end: CGPoint)
    let reach: CGFloat = 1.52866483
    let steps: [Step] = [
        (CGPoint(x: 1.08849296, y: 0), CGPoint(x: 0.86840694, y: 0), CGPoint(x: 0.63149379, y: 0.07491139)),
        (CGPoint(x: 0.37282383, y: 0.16905956), CGPoint(x: 0.16905956, y: 0.37282383), CGPoint(x: 0.07491139, y: 0.63149379)),
        (CGPoint(x: 0, y: 0.86840694), CGPoint(x: 0, y: 1.08849296), CGPoint(x: 0, y: reach)),
    ]
    let corners: [(corner: CGPoint, incoming: CGPoint, outgoing: CGPoint)] = [
        (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1)),
        (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: 0, y: -1), CGPoint(x: -1, y: 0)),
        (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: 1)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)),
    ]
    let path = CGMutablePath()
    func place(_ local: CGPoint, _ corner: CGPoint, _ incoming: CGPoint, _ outgoing: CGPoint) -> CGPoint {
        CGPoint(
            x: corner.x - incoming.x * local.x * radius + outgoing.x * local.y * radius,
            y: corner.y - incoming.y * local.x * radius + outgoing.y * local.y * radius
        )
    }
    let last = corners[3]
    path.move(to: place(CGPoint(x: 0, y: reach), last.corner, last.incoming, last.outgoing))
    for entry in corners {
        path.addLine(to: place(CGPoint(x: reach, y: 0), entry.corner, entry.incoming, entry.outgoing))
        for step in steps {
            path.addCurve(
                to: place(step.end, entry.corner, entry.incoming, entry.outgoing),
                control1: place(step.c1, entry.corner, entry.incoming, entry.outgoing),
                control2: place(step.c2, entry.corner, entry.incoming, entry.outgoing)
            )
        }
    }
    path.closeSubpath()
    return path
}

let rays: [Ray] = [
    Ray(angle: 4, length: 1.00, width: 0.72),
    Ray(angle: 32, length: 0.66, width: 1.00),
    Ray(angle: 61, length: 0.94, width: 0.86),
    Ray(angle: 93, length: 0.60, width: 0.92),
    Ray(angle: 121, length: 0.90, width: 0.76),
    Ray(angle: 150, length: 0.72, width: 1.00),
    Ray(angle: 178, length: 1.00, width: 0.74),
    Ray(angle: 208, length: 0.64, width: 0.96),
    Ray(angle: 237, length: 0.92, width: 0.82),
    Ray(angle: 267, length: 0.68, width: 1.00),
    Ray(angle: 296, length: 0.98, width: 0.76),
    Ray(angle: 325, length: 0.70, width: 0.94),
]

let glyphReach: CGFloat = 0.385
let glyphBaseWidth: CGFloat = 0.124
let glyphTipWidth: CGFloat = 0.092
let glyphHubRadius: CGFloat = 0.058

func rayPath(_ ray: Ray) -> CGPath {
    let baseHalf = glyphBaseWidth * ray.width * 0.5
    let tipHalf = glyphTipWidth * ray.width * 0.5
    let tipCenter = glyphReach * ray.length - tipHalf
    let shoulder = tipCenter * 0.45
    let shoulderHalf = baseHalf * 0.80 + tipHalf * 0.20
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: -baseHalf))
    path.addLine(to: CGPoint(x: shoulder, y: -shoulderHalf))
    path.addLine(to: CGPoint(x: tipCenter, y: -tipHalf))
    path.addArc(center: CGPoint(x: tipCenter, y: 0), radius: tipHalf, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
    path.addLine(to: CGPoint(x: shoulder, y: shoulderHalf))
    path.addLine(to: CGPoint(x: 0, y: baseHalf))
    path.closeSubpath()
    var transform = CGAffineTransform(rotationAngle: ray.angle * .pi / 180)
    return path.copy(using: &transform) ?? path
}

func drawGlyph(in context: CGContext, center: CGPoint, scale: CGFloat, rotation: CGFloat) {
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: rotation * .pi / 180)
    context.scaleBy(x: scale, y: scale)
    let shapes = CGMutablePath()
    for ray in rays { shapes.addPath(rayPath(ray)) }
    shapes.addEllipse(in: CGRect(x: -glyphHubRadius, y: -glyphHubRadius, width: glyphHubRadius * 2, height: glyphHubRadius * 2))

    func paint(shadowed: Bool) {
        context.saveGState()
        if shadowed {
            context.setShadow(offset: CGSize(width: 0, height: -5), blur: 12, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        }
        context.setFillColor(NSColor.white.cgColor)
        context.addPath(shapes)
        context.fillPath()
        context.restoreGState()
    }

    paint(shadowed: true)
    paint(shadowed: false)
    context.restoreGState()
}

func verticalGradient(top: NSColor, bottom: NSColor) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [top.cgColor, bottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
}

func fillGradient(_ gradient: CGGradient, in rect: CGRect, context: CGContext) {
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

func drawTile(_ tile: Tile, in context: CGContext, shadowAlpha: CGFloat, shadowOffset: CGSize, shadowBlur: CGFloat) {
    let path = squirclePath(tile.rect, radius: tileCornerRadius)
    let bottom = bottomColor(for: tile.topColor)

    context.saveGState()
    context.setShadow(offset: shadowOffset, blur: shadowBlur, color: NSColor.black.withAlphaComponent(shadowAlpha).cgColor)
    context.setFillColor(bottom.cgColor)
    context.addPath(path)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()
    fillGradient(verticalGradient(top: tile.topColor, bottom: bottom), in: tile.rect, context: context)
    let sheen = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [NSColor.white.withAlphaComponent(sheenAlpha).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        sheen,
        start: CGPoint(x: tile.rect.midX, y: tile.rect.maxY),
        end: CGPoint(x: tile.rect.midX, y: tile.rect.maxY - tile.rect.height * 0.45),
        options: []
    )
    drawGlyph(
        in: context,
        center: CGPoint(
            x: tile.rect.midX + tile.glyphShift.x * tile.rect.width,
            y: tile.rect.midY + tile.glyphShift.y * tile.rect.width
        ),
        scale: tile.rect.width * tile.glyphScale,
        rotation: tile.glyphRotation
    )
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()
    context.addPath(path)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()
}

let bodyRect = CGRect(
    x: (canvasSide - bodySide) / 2,
    y: (canvasSide - bodySide) / 2,
    width: bodySide,
    height: bodySide
)
let tileInset = (bodySide - tileSpan) / 2
let leftEdge = bodyRect.minX + tileInset
let bottomEdge = bodyRect.minY + tileInset
let travel = tileSpan - tileSide
let back = Tile(
    rect: CGRect(x: leftEdge, y: bottomEdge + travel, width: tileSide, height: tileSide),
    topColor: srgb(0xE30E7C),
    glyphRotation: 14,
    glyphShift: CGPoint(x: -0.07, y: 0.07),
    glyphScale: 0.92
)
let front = Tile(
    rect: CGRect(x: leftEdge + travel, y: bottomEdge, width: tileSide, height: tileSide),
    topColor: srgb(0xEB6941),
    glyphRotation: 0,
    glyphShift: .zero,
    glyphScale: 1
)

guard let context = CGContext(
    data: nil,
    width: Int(canvasSide),
    height: Int(canvasSide),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Could not create the icon canvas\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
context.interpolationQuality = .high

let bodyPath = squirclePath(bodyRect, radius: bodyCornerRadius)
let ivory = srgb(0xF4F1EA)
let ivoryShade = srgb(0xE9E4D9)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.30).cgColor)
context.setFillColor(ivoryShade.cgColor)
context.addPath(bodyPath)
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(bodyPath)
context.clip()
fillGradient(verticalGradient(top: ivory, bottom: ivoryShade), in: bodyRect, context: context)
drawTile(back, in: context, shadowAlpha: 0.16, shadowOffset: CGSize(width: -3, height: -8), shadowBlur: 16)
drawTile(front, in: context, shadowAlpha: 0.38, shadowOffset: CGSize(width: -6, height: -14), shadowBlur: 28)
context.restoreGState()

NSGraphicsContext.restoreGraphicsState()

guard let image = context.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fputs("Could not render icon\n", stderr)
    exit(1)
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
