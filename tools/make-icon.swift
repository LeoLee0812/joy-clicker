// 生成 AppIcon.icns：电光蓝圆角底板 + 白色竖握 Joy-Con（摇杆 + 十字键，→ 键标成红色 = 下一页）
// 用法：swift tools/make-icon.swift && iconutil -c icns AppIcon.iconset -o AppIcon.icns && rm -r AppIcon.iconset
import AppKit

let dir = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let neonBlue = NSColor(srgbRed: 0.04, green: 0.73, blue: 0.90, alpha: 1)   // Joy-Con 电光蓝
let deepBlue = NSColor(srgbRed: 0.00, green: 0.42, blue: 0.66, alpha: 1)
let neonRed = NSColor(srgbRed: 1.00, green: 0.24, blue: 0.16, alpha: 1)    // Joy-Con 电光红

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(px) / 1024
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * k, y: y * k, width: w * k, height: h * k) }
    func dot(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ c: NSColor) {
        c.setFill()
        NSBezierPath(ovalIn: rect(cx - r, cy - r, r * 2, r * 2)).fill()
    }
    // 底板：macOS 图标网格，824 见方、圆角 185，带一点落影
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.shadowBlurRadius = 24 * k
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let body = NSBezierPath(roundedRect: rect(100, 110, 824, 824), xRadius: 185 * k, yRadius: 185 * k)
    deepBlue.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: neonBlue, ending: deepBlue)!.draw(in: body, angle: -90)
    // 白色 Joy-Con
    NSColor.white.setFill()
    NSBezierPath(roundedRect: rect(372, 190, 280, 680), xRadius: 140 * k, yRadius: 140 * k).fill()
    // − 键
    NSBezierPath(roundedRect: rect(560, 788, 52, 16), xRadius: 8 * k, yRadius: 8 * k).fill(with: deepBlue)
    // 摇杆
    dot(512, 670, 70, deepBlue)
    dot(512, 670, 46, neonBlue)
    // 十字键：上下左右四个圆点，→ 是红的
    dot(512, 520, 38, deepBlue)
    dot(512, 340, 38, deepBlue)
    dot(422, 430, 38, deepBlue)
    dot(602, 430, 38, neonRed)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
}
print("==> \(dir)")
