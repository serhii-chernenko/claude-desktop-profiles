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

struct SourceGlyph {
    let image: CGImage
    let widthFraction: CGFloat
    let heightFraction: CGFloat
    let offset: CGPoint
}

struct SourcePixels {
    let side: Int
    let bytes: [UInt8]
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
    Ray(angle: 6, length: 0.90, width: 0.86),
    Ray(angle: 34, length: 0.82, width: 1.00),
    Ray(angle: 62, length: 0.94, width: 1.10),
    Ray(angle: 90, length: 0.88, width: 0.80),
    Ray(angle: 119, length: 1.00, width: 1.10),
    Ray(angle: 142, length: 0.93, width: 0.94),
    Ray(angle: 176, length: 0.86, width: 0.74),
    Ray(angle: 209, length: 0.80, width: 1.00),
    Ray(angle: 236, length: 0.86, width: 0.90),
    Ray(angle: 266, length: 0.80, width: 1.00),
    Ray(angle: 301, length: 0.84, width: 0.96),
    Ray(angle: 326, length: 0.88, width: 0.84),
]

let glyphReach: CGFloat = 0.375
let glyphRootHalfWidth: CGFloat = 0.009
let glyphTipHalfWidth: CGFloat = 0.033
let glyphTipRoundness: CGFloat = 0.55
let glyphHubRadius: CGFloat = 0.024

func rayPath(_ ray: Ray) -> CGPath {
    let rootHalf = glyphRootHalfWidth
    let tipHalf = glyphTipHalfWidth * ray.width
    let length = glyphReach * ray.length
    let shoulder = length - tipHalf * glyphTipRoundness * 2
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: -rootHalf))
    path.addLine(to: CGPoint(x: shoulder, y: -tipHalf))
    path.addQuadCurve(to: CGPoint(x: shoulder, y: tipHalf), control: CGPoint(x: length + tipHalf * 0.6, y: 0))
    path.addLine(to: CGPoint(x: 0, y: rootHalf))
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

let whiteValueFloor: CGFloat = 0.70
let whiteValueFull: CGFloat = 0.88
let whiteSaturationFull: CGFloat = 0.05
let whiteSaturationNone: CGFloat = 0.60
let tileSaturationFloor: CGFloat = 0.45
let tileValueFloor: CGFloat = 0.50
let glyphSizeRange: ClosedRange<CGFloat> = 0.30...0.95
let glyphMinimumPixels = 2000
let glyphCropMargin = 2
let sourceRenderSide = 1024

func ramp(_ value: CGFloat, from low: CGFloat, to high: CGFloat) -> CGFloat {
    min(1, max(0, (value - low) / (high - low)))
}

func renderSource(_ image: NSImage) -> SourcePixels? {
    let side = sourceRenderSide
    guard let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: side * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let data = context.data else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: side * side * 4))
    return SourcePixels(side: side, bytes: bytes)
}

func whiteness(at index: Int, in bytes: [UInt8]) -> CGFloat {
    let alpha = CGFloat(bytes[index + 3]) / 255
    guard alpha > 0.5 else { return 0 }
    let red = CGFloat(bytes[index]) / 255 / alpha
    let green = CGFloat(bytes[index + 1]) / 255 / alpha
    let blue = CGFloat(bytes[index + 2]) / 255 / alpha
    let top = max(red, green, blue)
    guard top > 0 else { return 0 }
    let saturation = (top - min(red, green, blue)) / top
    let brightness = ramp(top, from: whiteValueFloor, to: whiteValueFull)
    let paleness = 1 - ramp(saturation, from: whiteSaturationFull, to: whiteSaturationNone)
    return brightness * paleness * alpha
}

func tileSide(in pixels: SourcePixels) -> (side: CGFloat, minX: Int, minY: Int)? {
    let side = pixels.side
    var minX = side, maxX = -1, minY = side, maxY = -1
    for y in 0..<side {
        for x in 0..<side {
            let index = (y * side + x) * 4
            let alpha = CGFloat(pixels.bytes[index + 3]) / 255
            guard alpha > 0.9 else { continue }
            let red = CGFloat(pixels.bytes[index]) / 255 / alpha
            let green = CGFloat(pixels.bytes[index + 1]) / 255 / alpha
            let blue = CGFloat(pixels.bytes[index + 2]) / 255 / alpha
            let top = max(red, green, blue)
            guard top > tileValueFloor, (top - min(red, green, blue)) / top > tileSaturationFloor else { continue }
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX > minX, maxY > minY else { return nil }
    return (CGFloat(max(maxX - minX, maxY - minY) + 1), minX, minY)
}

func connectedCore(from mask: [CGFloat], side: Int) -> [Bool] {
    var core = [Bool](repeating: false, count: side * side)
    var seed: Int?
    var bestDistance = Int.max
    let middle = side / 2
    for y in 0..<side {
        for x in 0..<side where mask[y * side + x] > 0.5 {
            let distance = (x - middle) * (x - middle) + (y - middle) * (y - middle)
            if distance < bestDistance { bestDistance = distance; seed = y * side + x }
        }
    }
    guard let start = seed else { return core }
    var queue = [start]
    core[start] = true
    var head = 0
    while head < queue.count {
        let current = queue[head]
        head += 1
        let x = current % side, y = current / side
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, ny >= 0, nx < side, ny < side else { continue }
            let neighbor = ny * side + nx
            if !core[neighbor] && mask[neighbor] > 0.5 {
                core[neighbor] = true
                queue.append(neighbor)
            }
        }
    }
    return core
}

func dilate(_ cells: [Bool], side: Int, passes: Int) -> [Bool] {
    var current = cells
    for _ in 0..<passes {
        var next = current
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) where !current[y * side + x] {
                outer: for dy in -1...1 {
                    for dx in -1...1 where current[(y + dy) * side + x + dx] {
                        next[y * side + x] = true
                        break outer
                    }
                }
            }
        }
        current = next
    }
    return current
}

func extractGlyph(from pixels: SourcePixels) -> SourceGlyph? {
    let side = pixels.side
    guard let tile = tileSide(in: pixels) else { return nil }
    var mask = [CGFloat](repeating: 0, count: side * side)
    for pixel in 0..<(side * side) {
        mask[pixel] = whiteness(at: pixel * 4, in: pixels.bytes)
    }
    let reach = dilate(connectedCore(from: mask, side: side), side: side, passes: 3)
    var minX = side, maxX = -1, minY = side, maxY = -1
    var opaquePixels = 0
    for y in 0..<side {
        for x in 0..<side {
            let index = y * side + x
            if !reach[index] { mask[index] = 0 }
            guard mask[index] > 0.5 else { continue }
            opaquePixels += 1
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard opaquePixels >= glyphMinimumPixels else { return nil }
    let cropMinX = max(0, minX - glyphCropMargin), cropMaxX = min(side - 1, maxX + glyphCropMargin)
    let cropMinY = max(0, minY - glyphCropMargin), cropMaxY = min(side - 1, maxY + glyphCropMargin)
    let width = cropMaxX - cropMinX + 1, height = cropMaxY - cropMinY + 1
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let value = UInt8((mask[(cropMinY + y) * side + cropMinX + x] * 255).rounded())
            let offset = (y * width + x) * 4
            rgba[offset] = value; rgba[offset + 1] = value; rgba[offset + 2] = value; rgba[offset + 3] = value
        }
    }
    let image: CGImage? = rgba.withUnsafeMutableBytes { buffer in
        CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }
    guard let glyphImage = image else { return nil }
    let widthFraction = CGFloat(maxX - minX + 1) / tile.side
    let heightFraction = CGFloat(maxY - minY + 1) / tile.side
    guard glyphSizeRange.contains(max(widthFraction, heightFraction)) else { return nil }
    let tileCenterX = CGFloat(tile.minX) + tile.side / 2
    let tileCenterY = CGFloat(tile.minY) + tile.side / 2
    let glyphCenterX = CGFloat(minX + maxX + 1) / 2
    let glyphCenterY = CGFloat(minY + maxY + 1) / 2
    return SourceGlyph(
        image: glyphImage,
        widthFraction: CGFloat(width) / CGFloat(maxX - minX + 1) * widthFraction,
        heightFraction: CGFloat(height) / CGFloat(maxY - minY + 1) * heightFraction,
        offset: CGPoint(
            x: (glyphCenterX - tileCenterX) / tile.side,
            y: (tileCenterY - glyphCenterY) / tile.side
        )
    )
}

func sourceCandidates(for path: String) -> [(label: String, image: NSImage)] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return [] }
    guard isDirectory.boolValue else {
        return NSImage(contentsOfFile: path).map { [(path, $0)] } ?? []
    }
    var candidates: [(String, NSImage)] = [("\(path) (system icon)", NSWorkspace.shared.icon(forFile: path))]
    let resources = path + "/Contents/Resources"
    let icnsNames = ((try? FileManager.default.contentsOfDirectory(atPath: resources)) ?? []).filter { $0.hasSuffix(".icns") }.sorted()
    for name in icnsNames {
        if let image = NSImage(contentsOfFile: resources + "/" + name) { candidates.append(("\(resources)/\(name)", image)) }
    }
    return candidates
}

func loadSourceGlyph() -> SourceGlyph? {
    let environment = ProcessInfo.processInfo.environment
    guard environment["ICON_GLYPH"] != "generic" else { return nil }
    let path = environment["CLAUDE_ICON_SOURCE"] ?? "/Applications/Claude.app"
    for candidate in sourceCandidates(for: path) {
        guard let pixels = renderSource(candidate.image), let glyph = extractGlyph(from: pixels) else { continue }
        fputs("make-icon: glyph extracted from \(candidate.label)\n", stderr)
        return glyph
    }
    fputs("make-icon: no usable glyph source, drawing the generic glyph\n", stderr)
    return nil
}

func drawSourceGlyph(_ glyph: SourceGlyph, in context: CGContext, tile: Tile) {
    let width = glyph.widthFraction * tile.rect.width
    let height = glyph.heightFraction * tile.rect.width
    context.saveGState()
    context.translateBy(
        x: tile.rect.midX + (glyph.offset.x + tile.glyphShift.x) * tile.rect.width,
        y: tile.rect.midY + (glyph.offset.y + tile.glyphShift.y) * tile.rect.width
    )
    context.rotate(by: tile.glyphRotation * .pi / 180)
    context.scaleBy(x: tile.glyphScale, y: tile.glyphScale)
    let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
    context.setShadow(offset: CGSize(width: 0, height: -5), blur: 12, color: NSColor.black.withAlphaComponent(0.18).cgColor)
    context.draw(glyph.image, in: rect)
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.draw(glyph.image, in: rect)
    context.restoreGState()
}

let sourceGlyph = loadSourceGlyph()

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
    if let sourceGlyph {
        drawSourceGlyph(sourceGlyph, in: context, tile: tile)
    } else {
        drawGlyph(
            in: context,
            center: CGPoint(
                x: tile.rect.midX + tile.glyphShift.x * tile.rect.width,
                y: tile.rect.midY + tile.glyphShift.y * tile.rect.width
            ),
            scale: tile.rect.width * tile.glyphScale,
            rotation: tile.glyphRotation
        )
    }
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
