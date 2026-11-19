// Renders Inset's app icon into an .iconset folder.  Usage: swift make_icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // macOS icon grid: 824/1024 body with soft drop shadow.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0, 0, 0, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0.08, 0.08, 0.11))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0.13, 0.12, 0.20), color(0.05, 0.05, 0.08)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // Screen layer.
    let screen = CGRect(x: body.minX + body.width * 0.12, y: body.minY + body.height * 0.27, width: body.width * 0.76, height: body.height * 0.52)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: screen.height * 0.12, cornerHeight: screen.height * 0.12, transform: nil)
    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()
    let sg = CGGradient(colorsSpace: space, colors: [color(0.27, 0.32, 0.86), color(0.50, 0.38, 1.0), color(0.30, 0.78, 1.0)] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(sg, start: CGPoint(x: screen.minX, y: screen.minY), end: CGPoint(x: screen.maxX, y: screen.maxY), options: [])
    // window chrome hint
    ctx.setFillColor(color(1, 1, 1, 0.16))
    ctx.fill(CGRect(x: screen.minX, y: screen.maxY - screen.height * 0.13, width: screen.width, height: screen.height * 0.13))
    for i in 0..<3 {
        ctx.setFillColor(color(1, 1, 1, 0.55))
        let d = screen.height * 0.055
        ctx.fillEllipse(in: CGRect(x: screen.minX + screen.height * 0.07 + CGFloat(i) * d * 1.7, y: screen.maxY - screen.height * 0.093, width: d, height: d))
    }
    for i in 0..<3 {
        ctx.setFillColor(color(1, 1, 1, 0.28))
        let w = screen.width * [0.46, 0.34, 0.40][i]
        let h = screen.height * 0.06
        let y = screen.maxY - screen.height * (0.30 + CGFloat(i) * 0.15)
        ctx.addPath(CGPath(roundedRect: CGRect(x: screen.minX + screen.width * 0.08, y: y, width: w, height: h), cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // Camera bubble.
    let d = body.width * 0.40
    let cam = CGRect(x: body.maxX - d - body.width * 0.07, y: body.minY + body.height * 0.08, width: d, height: d)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.035, color: color(0, 0, 0, 0.55))
    ctx.setFillColor(color(1, 1, 1))
    ctx.fillEllipse(in: cam)
    ctx.restoreGState()
    let ring = s * 0.016
    let inner = cam.insetBy(dx: ring, dy: ring)
    ctx.saveGState()
    ctx.addEllipse(in: inner)
    ctx.clip()
    let cg = CGGradient(colorsSpace: space, colors: [color(1.0, 0.58, 0.36), color(0.95, 0.28, 0.52)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(cg, start: CGPoint(x: inner.minX, y: inner.maxY), end: CGPoint(x: inner.maxX, y: inner.minY), options: [])
    ctx.setFillColor(color(1, 1, 1, 0.95))
    let head = inner.width * 0.30
    ctx.fillEllipse(in: CGRect(x: inner.midX - head / 2, y: inner.midY - head * 0.05, width: head, height: head))
    let shoulders = inner.width * 0.64
    ctx.fillEllipse(in: CGRect(x: inner.midX - shoulders / 2, y: inner.minY - shoulders * 0.42, width: shoulders, height: shoulders * 0.85))
    ctx.restoreGState()

    // Recording dot.
    let dot = body.width * 0.075
    ctx.setFillColor(color(1.0, 0.27, 0.30))
    ctx.fillEllipse(in: CGRect(x: screen.maxX - dot * 1.6, y: screen.maxY - dot * 1.55, width: dot, height: dot))
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
print("icon → \(out.path)")
