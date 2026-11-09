// 应用图标渲染器（独立脚本，由 build.sh 调用）
//
// 按设计稿 1:1 还原：
//   画布 220 → 深色渐变圆角底（#2a2f3f → #1b1f2b，圆角 48）
//   内部 stack 140×100 居中；单屏 110×72、圆角 10、2px 描边
//   后方屏幕左上、rotate(-3deg) scale(0.92)、亮度 65%
//   前方屏幕右下偏移 (30,28)、rotate(2deg)、带投影
//   每屏三条内容条（#8cc8ff 三档透明度），外加一层玻璃反光
//
// 用法：swift AppIconGen.swift <输出 png 路径>

import Cocoa

let designBase: CGFloat = 220

func col(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

func rgbSpace() -> CGColorSpace { CGColorSpaceCreateDeviceRGB() }

/// 画一块屏幕：底、玻璃反光、三条内容条、描边。
func drawScreen(_ cg: CGContext,
                rect: CGRect,
                radius: CGFloat,
                fill: CGColor,
                border: CGColor,
                bars: [CGColor],
                k: CGFloat,
                shadow: (offset: CGSize, blur: CGFloat, color: CGColor)? = nil) {

    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    cg.saveGState()
    if let s = shadow {
        cg.setShadow(offset: s.offset, blur: s.blur, color: s.color)
    }
    cg.addPath(path)
    cg.setFillColor(fill)
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(path)
    cg.clip()

    // 玻璃反光：135deg，从左上 0.12 衰减到 65% 处完全透明
    if let glass = CGGradient(colorsSpace: rgbSpace(),
                              colors: [col(0xFFFFFF, 0.12), col(0xFFFFFF, 0.03), col(0xFFFFFF, 0.0)] as CFArray,
                              locations: [0, 0.4, 0.65]) {
        cg.drawLinearGradient(glass,
                              start: CGPoint(x: rect.minX, y: rect.minY),
                              end: CGPoint(x: rect.maxX, y: rect.maxY),
                              options: [])
    }

    // 内容条：padding 左右 12 + 描边 2，三条间隔 11
    let inset = 14 * k
    let barW = rect.width - inset * 2
    for (i, color) in bars.enumerated() {
        let y = rect.minY + 2 * k + (16 + CGFloat(i) * 11) * k
        let bar = CGRect(x: rect.minX + inset, y: y, width: barW, height: 4 * k)
        cg.addPath(CGPath(roundedRect: bar, cornerWidth: 2 * k, cornerHeight: 2 * k, transform: nil))
        cg.setFillColor(color)
        cg.fillPath()
    }
    cg.restoreGState()

    // 2px 描边（CSS 的 border 在 border-box 内，所以往里缩 1px）
    cg.addPath(CGPath(roundedRect: rect.insetBy(dx: 1 * k, dy: 1 * k),
                      cornerWidth: radius - 1 * k, cornerHeight: radius - 1 * k,
                      transform: nil))
    cg.setStrokeColor(border)
    cg.setLineWidth(2 * k)
    cg.strokePath()
}

func drawIcon(_ cg: CGContext, pixelSize: CGFloat) {
    let k = pixelSize / designBase

    // 设计稿为左上原点
    cg.translateBy(x: 0, y: pixelSize)
    cg.scaleBy(x: 1, y: -1)

    let canvas = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    let iconRadius = 48 * k
    let iconPath = CGPath(roundedRect: canvas, cornerWidth: iconRadius, cornerHeight: iconRadius, transform: nil)

    // 底色：145deg 深色渐变
    cg.saveGState()
    cg.addPath(iconPath)
    cg.clip()
    if let bg = CGGradient(colorsSpace: rgbSpace(),
                           colors: [col(0x2A2F3F), col(0x1B1F2B)] as CFArray,
                           locations: [0, 1]) {
        cg.drawLinearGradient(bg,
                              start: CGPoint(x: pixelSize * 0.05, y: 0),
                              end: CGPoint(x: pixelSize * 0.95, y: pixelSize),
                              options: [])
    }
    // 底部极淡的蓝色辉光，对应设计稿图标下缘的反光
    if let glow = CGGradient(colorsSpace: rgbSpace(),
                             colors: [col(0x78B4FF, 0.10), col(0x78B4FF, 0.0)] as CFArray,
                             locations: [0, 1]) {
        cg.drawRadialGradient(glow,
                              startCenter: CGPoint(x: pixelSize * 0.5, y: pixelSize * 1.02),
                              startRadius: 0,
                              endCenter: CGPoint(x: pixelSize * 0.5, y: pixelSize * 1.02),
                              endRadius: pixelSize * 0.55,
                              options: [])
    }
    cg.restoreGState()

    // 顶部内高光
    cg.addPath(CGPath(roundedRect: canvas.insetBy(dx: 0.5 * k, dy: 0.5 * k),
                      cornerWidth: iconRadius, cornerHeight: iconRadius, transform: nil))
    cg.setStrokeColor(col(0xFFFFFF, 0.07))
    cg.setLineWidth(1 * k)
    cg.strokePath()

    // ---- 双屏 ----
    let stackX = 40 * k
    let stackY = 60 * k
    let screenW = 110 * k
    let screenH = 72 * k
    let screenRadius = 10 * k
    let size = CGSize(width: screenW, height: screenH)

    func transformed(origin: CGPoint, degrees: CGFloat, scale: CGFloat, body: () -> Void) {
        let center = CGPoint(x: origin.x + screenW / 2, y: origin.y + screenH / 2)
        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y)
        cg.rotate(by: degrees * .pi / 180)
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -center.x, y: -center.y)
        body()
        cg.restoreGState()
    }

    // 后方屏幕：左上，亮度压到 65%
    let backOrigin = CGPoint(x: stackX, y: stackY)
    let backRect = CGRect(origin: backOrigin, size: size)
    transformed(origin: backOrigin, degrees: -3, scale: 0.92) {
        drawScreen(cg, rect: backRect, radius: screenRadius,
                   fill: col(0x0F131C), border: col(0x3C4356),
                   bars: [col(0x6496D2, 0.35), col(0x6496D2, 0.15), col(0x6496D2, 0.08)],
                   k: k)
        // brightness(0.65) 等价于整体压一层黑
        cg.saveGState()
        cg.addPath(CGPath(roundedRect: backRect, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil))
        cg.clip()
        cg.setFillColor(col(0x000000, 0.35))
        cg.fill(backRect)
        cg.restoreGState()
    }

    // 前方屏幕：右下，活动态
    let frontOrigin = CGPoint(x: stackX + 30 * k, y: stackY + 28 * k)
    let frontRect = CGRect(origin: frontOrigin, size: size)
    transformed(origin: frontOrigin, degrees: 2, scale: 1) {
        drawScreen(cg, rect: frontRect, radius: screenRadius,
                   fill: col(0x1C2333), border: col(0x5A6580),
                   bars: [col(0x8CC8FF, 0.75), col(0x8CC8FF, 0.35), col(0x8CC8FF, 0.18)],
                   k: k,
                   shadow: (CGSize(width: 0, height: -12 * k), 22 * k, col(0x000000, 0.85)))
    }
}

func renderRep(pixels: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels,
                                     pixelsHigh: pixels,
                                     bitsPerSample: 8,
                                     samplesPerPixel: 4,
                                     hasAlpha: true,
                                     isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0,
                                     bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let cg = ctx.cgContext
    cg.setShouldAntialias(true)
    cg.interpolationQuality = .high
    cg.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))

    drawIcon(cg, pixelSize: CGFloat(pixels))

    NSGraphicsContext.restoreGraphicsState()

    return rep
}

func renderPNG(pixels: Int) -> Data? {
    renderRep(pixels: pixels)?.representation(using: .png, properties: [:])
}

// MARK: - Windows .ico

/// 单帧：32bpp BGRA DIB，像素行自下而上，末尾附 1bpp AND 掩码。
/// Windows 的 ICO 用的是非预乘 alpha，而 NSColor 取出的分量本来就是直通值，可直接写。
func dibFrame(rep: NSBitmapImageRep, size: Int) -> Data {
    var out = Data()
    func put32(_ v: UInt32) { var x = v.littleEndian; out.append(Data(bytes: &x, count: 4)) }
    func put16(_ v: UInt16) { var x = v.littleEndian; out.append(Data(bytes: &x, count: 2)) }

    let maskStride = ((size + 31) / 32) * 4

    put32(40)                    // BITMAPINFOHEADER
    put32(UInt32(size))          // biWidth
    put32(UInt32(size * 2))      // biHeight = XOR + AND
    put16(1)                     // biPlanes
    put16(32)                    // biBitCount
    put32(0)                     // BI_RGB
    put32(UInt32(size * size * 4 + maskStride * size))
    put32(0); put32(0); put32(0); put32(0)

    for y in stride(from: size - 1, through: 0, by: -1) {
        for x in 0..<size {
            let src = rep.colorAt(x: x, y: y) ?? NSColor.clear
            let c = src.usingColorSpace(.deviceRGB) ?? NSColor.clear
            out.append(UInt8(clamping: Int((c.blueComponent * 255).rounded())))
            out.append(UInt8(clamping: Int((c.greenComponent * 255).rounded())))
            out.append(UInt8(clamping: Int((c.redComponent * 255).rounded())))
            out.append(UInt8(clamping: Int((c.alphaComponent * 255).rounded())))
        }
    }

    // AND 掩码全 0，透明度交给 alpha 通道
    out.append(Data(count: maskStride * size))
    return out
}

func icoData() -> Data {
    let sizes = [16, 32, 48, 64, 128, 256]
    var frames: [(Int, Data)] = []
    for s in sizes {
        guard let rep = renderRep(pixels: s) else { continue }
        frames.append((s, dibFrame(rep: rep, size: s)))
    }

    var out = Data()
    out.append(contentsOf: [0, 0, 1, 0])                    // reserved / type=icon
    var count = UInt16(frames.count).littleEndian
    out.append(Data(bytes: &count, count: 2))

    var offset = 6 + 16 * frames.count
    for (s, data) in frames {
        let dim = s >= 256 ? 0 : s
        out.append(contentsOf: [UInt8(dim), UInt8(dim), 0, 0])
        var planes = UInt16(1).littleEndian
        var bpp = UInt16(32).littleEndian
        out.append(Data(bytes: &planes, count: 2))
        out.append(Data(bytes: &bpp, count: 2))
        var length = UInt32(data.count).littleEndian
        out.append(Data(bytes: &length, count: 4))
        var off = UInt32(offset).littleEndian
        out.append(Data(bytes: &off, count: 4))
        offset += data.count
    }
    for (_, data) in frames { out.append(data) }
    return out
}

// MARK: - 入口

let args = CommandLine.arguments

if args.count >= 3 && args[1] == "--ico" {
    let data = icoData()
    do {
        try data.write(to: URL(fileURLWithPath: args[2]))
        print("ico written: \(args[2]) (\(data.count) bytes)")
        exit(0)
    } catch {
        FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

let outPath = args.count > 1 ? args[1] : "AppIcon-master.png"

guard let data = renderPNG(pixels: 1024) else {
    FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
    exit(1)
}

do {
    try data.write(to: URL(fileURLWithPath: outPath))
    print("icon rendered: \(outPath) (\(data.count) bytes)")
} catch {
    FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
