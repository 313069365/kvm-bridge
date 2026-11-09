import Cocoa

/// 轻量浮动提示：出现在菜单栏下方，两秒后自动淡出。
///
/// 不用 UNUserNotificationCenter 的原因：它要求应用有有效的开发者签名，
/// 自签名应用请求授权会被系统拒绝，而且失败是静默的。
/// 这个浮层不依赖任何权限，行为确定。
///
/// 全进程复用一个面板。早期版本每次新建，连续两条提示会把上一条的关闭任务
/// 取消掉，旧面板就永远留在屏幕上了。
final class Toast {

    static let shared = Toast()

    private let padding: CGFloat = 18
    private var hideWork: DispatchWorkItem?

    private lazy var label: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        l.textColor = .labelColor
        l.lineBreakMode = .byTruncatingTail
        l.alignment = .center
        return l
    }()

    private lazy var content: NSView = {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 38))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        v.layer?.cornerRadius = 10
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.separatorColor.cgColor
        v.addSubview(label)
        return v
    }()

    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 38),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = content
        p.alphaValue = 0
        return p
    }()

    func show(_ text: String, seconds: TimeInterval = 2.6) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.hideWork?.cancel()

            self.label.stringValue = text
            self.label.sizeToFit()

            let labelWidth = min(max(self.label.frame.width + 4, 40), 420)
            self.label.frame = NSRect(x: self.padding, y: 10, width: labelWidth, height: 18)

            let size = NSSize(width: labelWidth + self.padding * 2, height: 38)
            self.content.frame = NSRect(origin: .zero, size: size)
            self.label.frame.origin.x = self.padding
            self.panel.setContentSize(size)

            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                self.panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2,
                                                  y: f.maxY - size.height - 10))
            }

            self.panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.panel.animator().alphaValue = 1
            }

            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    self.panel.animator().alphaValue = 0
                }, completionHandler: {
                    self.panel.orderOut(nil)
                })
            }
            self.hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }
}
