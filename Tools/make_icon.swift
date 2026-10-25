// Draws the app icon (a viewfinder with its anchor point) into an .iconset folder.
//   swift Tools/make_icon.swift <dossier.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = s * 0.1, body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = CGPath(roundedRect: body, cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil)
    ctx.addPath(shape); ctx.clip()
    let colors = [CGColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1), CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)]
    ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    // Three offset "photos" falling into line.
    ctx.setLineWidth(s * 0.012)
    for (i, a) in [(-0.16), (-0.07), 0.0].enumerated() {
        ctx.saveGState()
        ctx.translateBy(x: s / 2, y: s / 2)
        ctx.rotate(by: a)
        let o = CGFloat(2 - i) * s * 0.035
        let r = CGRect(x: -s * 0.27 - o, y: -s * 0.19 + o, width: s * 0.54, height: s * 0.38)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18 + 0.2 * CGFloat(i)))
        ctx.stroke(r)
        ctx.restoreGState()
    }
    let orange = CGColor(red: 1, green: 0.62, blue: 0.04, alpha: 1)
    ctx.setStrokeColor(orange)
    ctx.setLineWidth(s * 0.03)
    ctx.setLineCap(.round)
    let c = CGPoint(x: s / 2, y: s / 2), r = s * 0.1
    ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
        ctx.move(to: CGPoint(x: c.x + dx * (r + s * 0.04), y: c.y + dy * (r + s * 0.04)))
        ctx.addLine(to: CGPoint(x: c.x + dx * (r + s * 0.14), y: c.y + dy * (r + s * 0.14)))
    }
    ctx.strokePath()
    ctx.setFillColor(orange)
    ctx.fillEllipse(in: CGRect(x: c.x - s * 0.018, y: c.y - s * 0.018, width: s * 0.036, height: s * 0.036))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
