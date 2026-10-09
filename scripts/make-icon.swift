import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make-icon.swift OUTPUT.png\n", stderr)
    exit(2)
}

let side: CGFloat = 1024
let tileInset: CGFloat = 100
let tileRadius: CGFloat = 185

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

let cards: [(origin: NSPoint, top: NSColor, bottom: NSColor)] = [
    (NSPoint(x: 212, y: 392), color(96, 165, 250), color(37, 99, 235)),
    (NSPoint(x: 332, y: 302), color(74, 222, 128), color(22, 163, 74)),
    (NSPoint(x: 452, y: 212), color(251, 146, 60), color(234, 88, 12)),
]
let cardSide: CGFloat = 360
let cardRadius: CGFloat = 84

let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
    let tile = NSRect(x: tileInset, y: tileInset, width: side - tileInset * 2, height: side - tileInset * 2)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tileRadius, yRadius: tileRadius)

    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    tileShadow.shadowBlurRadius = 24
    tileShadow.shadowOffset = NSSize(width: 0, height: -10)
    tileShadow.set()
    color(246, 247, 250).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: color(252, 252, 254), ending: color(226, 230, 238))!.draw(in: tilePath, angle: -90)
    color(0, 0, 0, 0.06).setStroke()
    tilePath.lineWidth = 2
    tilePath.stroke()

    for card in cards {
        let rect = NSRect(origin: card.origin, size: NSSize(width: cardSide, height: cardSide))
        let path = NSBezierPath(roundedRect: rect, xRadius: cardRadius, yRadius: cardRadius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        card.bottom.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: card.top, ending: card.bottom)!.draw(in: path, angle: -90)
        NSColor.white.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 4
        path.stroke()
    }

    let front = cards[cards.count - 1]
    let center = NSPoint(x: front.origin.x + cardSide / 2, y: front.origin.y + cardSide / 2)
    NSColor.white.withAlphaComponent(0.95).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 52, y: center.y + 6, width: 104, height: 104)).fill()
    let shoulders = NSBezierPath()
    shoulders.move(to: NSPoint(x: center.x - 110, y: center.y - 120))
    shoulders.curve(to: NSPoint(x: center.x + 110, y: center.y - 120),
                    controlPoint1: NSPoint(x: center.x - 110, y: center.y + 10),
                    controlPoint2: NSPoint(x: center.x + 110, y: center.y + 10))
    shoulders.close()
    shoulders.fill()
    return true
}

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let data = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not render icon\n", stderr)
    exit(1)
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
