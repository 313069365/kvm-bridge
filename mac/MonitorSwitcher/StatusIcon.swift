import Cocoa

/// 菜单栏图标：交叉叠放的双屏。
///
/// 几何与透明度按设计稿 1:1 还原（基准 22×22）：
///   mini-stack 18×14 居中；单屏 13×10、圆角 2；
///   后方屏幕左上对齐、alpha 0.30；前方屏幕右下偏移 (5,4)、alpha 0.78；
///   每屏内部顶端有一条 1.5px 的标题栏亮条（设计稿里的 ::before）。
///
/// 用 template 模式：系统按菜单栏明暗自动反色，同时 alpha 差保留前后层次。
enum StatusIcon {

    static func make(size: CGFloat = 22) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        // 1x / 2x 各渲染一份，Retina 下才不糊
        for scale in [CGFloat(1), CGFloat(2)] {
            if let rep = render(size: size, scale: scale) {
                image.addRepresentation(rep)
            }
        }
        image.isTemplate = true
        return image
    }

    private static func render(size: CGFloat, scale: CGFloat) -> NSBitmapImageRep? {
        let px = Int((size * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: px,
                                         pixelsHigh: px,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        rep.size = NSSize(width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        defer { NSGraphicsContext.restoreGraphicsState() }

        let cg = ctx.cgContext
        cg.setShouldAntialias(true)
        cg.interpolationQuality = .high

        // NSGraphicsContext 的用户空间按像素计，先放大回点坐标（2x 就是 ×2），
        // 否则 2x 那份只画了设计尺寸的 1/4。
        let pixelScale = CGFloat(px) / size
        cg.scaleBy(x: pixelScale, y: pixelScale)

        // 设计稿是左上原点，翻一下坐标系，后面就能直接照搬设计数值
        cg.translateBy(x: 0, y: size)
        cg.scaleBy(x: 1, y: -1)

        draw(cg, size: size)
        return rep
    }

    private static func draw(_ cg: CGContext, size: CGFloat) {
        let k = size / 22.0

        // mini-stack：18×14，在 22×22 里居中
        let stackW = 18 * k
        let stackH = 14 * k
        let ox = (size - stackW) / 2
        let oy = (size - stackH) / 2

        let sw = 13 * k
        let sh = 10 * k
        let radius = 2 * k
        let barH = 1.5 * k
        let barInset = 1.5 * k

        // 后方屏幕左上对齐；前方屏幕右下对齐，即相对偏移 (5,4)
        let back = CGRect(x: ox, y: oy, width: sw, height: sh)
        let front = CGRect(x: ox + 5 * k, y: oy + 4 * k, width: sw, height: sh)

        func fillRounded(_ rect: CGRect, _ r: CGFloat, _ alpha: CGFloat) {
            cg.setFillColor(CGColor(gray: 0, alpha: alpha))
            cg.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
            cg.fillPath()
        }

        func titleBar(_ screen: CGRect, _ alpha: CGFloat) {
            let bar = CGRect(x: screen.minX + barInset,
                             y: screen.minY + barInset,
                             width: sw - barInset * 2,
                             height: barH)
            fillRounded(bar, barH / 2, alpha)
        }

        // 后方屏幕（略暗）
        fillRounded(back, radius, 0.30)
        titleBar(back, 0.30)

        // 沿前方屏幕外扩清空，制造两块屏之间的间隙，
        // 对应设计稿前方屏幕外面那圈 0.5px 亮边所表达的分离感。
        cg.saveGState()
        cg.setBlendMode(.clear)
        cg.fill(front.insetBy(dx: -1.0 * k, dy: -1.0 * k))
        cg.restoreGState()

        // 前方屏幕（活动、更亮）
        fillRounded(front, radius, 0.78)
        titleBar(front, 0.40)
    }
}
