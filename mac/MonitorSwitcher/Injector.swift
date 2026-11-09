import Cocoa
import CoreGraphics

/// 把对端发来的键鼠事件注入本机。
/// 只在共享模式下、且本机正在持有屏幕时调用。
///
/// 两个关键点：
/// 1. 事件打上 injectTag，事件泵据此识别「自己人」，既不回传也不计入本地输入。
/// 2. 维护修饰键状态，并把 flags 带到每一个按键事件上。
///    macOS 的组合键语义靠 event.flags，只发 Ctrl 的 keyDown 不会让后续的 C 带上 Ctrl。
enum Injector {

    private static let source = CGEventSource(stateID: .hidSystemState)

    private static var flags: CGEventFlags = []
    private static var pressedKeys: [UInt16: Bool] = [:]

    /// 自己维护光标位置：每个移动事件都去查一次系统光标会创建临时 CGEvent，
    /// 高频下是可见的开销。以下三种情况必须重新对齐，否则远端鼠标会「跳回旧位置」：
    /// ① 空闲 300ms 以上；② 本机刚有过真实鼠标输入；③ 缓存跑出了屏幕边界。
    private static var cursor: CGPoint?
    private static var lastMoveAt = Date.distantPast

    /// 光标不能越出当前显示屏；虚拟坐标必须跟真实光标一起被夹住，
    /// 否则贴边后内部坐标会继续累加，反向要甩很久才有反应（表现为鼠标卡死）。
    private static func clamp(_ p: CGPoint) -> CGPoint {
        let b = CGDisplayBounds(CGMainDisplayID())
        guard b.width > 2, b.height > 2 else { return p }
        return CGPoint(x: min(max(p.x, b.minX + 1), b.maxX - 2),
                       y: min(max(p.y, b.minY + 1), b.maxY - 2))
    }

    // MARK: - 键

    static func key(vk: UInt16, down: Bool) {
        if let flag = modifierFlag(for: vk) {
            if down {
                flags.insert(flag)
            } else {
                flags.remove(flag)
            }
        }

        guard let code = KeyMap.macKeyCode(forVK: vk) else { return }
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: CGKeyCode(code),
                                  keyDown: down) else { return }

        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: EventTapMonitor.injectTag)
        event.post(tap: .cghidEventTap)

        if down { pressedKeys[vk] = true } else { pressedKeys.removeValue(forKey: vk) }
    }

    /// Windows VK → macOS 修饰键 flag。同时接受左/右专用值和通用值。
    private static func modifierFlag(for vk: UInt16) -> CGEventFlags? {
        switch vk {
        case 0xA0, 0xA1, 0x10: return .maskShift
        case 0xA2, 0xA3, 0x11: return .maskControl
        case 0xA4, 0xA5, 0x12: return .maskAlternate
        case 0x5B, 0x5C, 0x5D: return .maskCommand
        default: return nil
        }
    }

    // MARK: - 鼠标

    static func mouseMove(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }

        let now = Date()
        // 本机用户碰了 Mac 上的真实鼠标后，缓存的虚拟坐标已经失效。
        // 注入事件带 tag，不会更新 lastLocalMouse，所以这里不会自己触发自己。
        let touchedLocally = EventTapMonitor.shared.lastLocalMouse > lastMoveAt
        if cursor == nil || touchedLocally || now.timeIntervalSince(lastMoveAt) > 0.3 {
            if let pos = CGEvent(source: nil)?.location { cursor = clamp(pos) }
        }
        lastMoveAt = now

        guard let base = cursor else { return }
        let target = clamp(CGPoint(x: base.x + CGFloat(dx), y: base.y + CGFloat(dy)))
        cursor = target
        guard let event = CGEvent(mouseEventSource: source,
                                  mouseType: .mouseMoved,
                                  mouseCursorPosition: target,
                                  mouseButton: .left) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: EventTapMonitor.injectTag)
        event.post(tap: .cghidEventTap)
    }

    static func mouseButton(_ button: Int, down: Bool) {
        // 点击必须落在真实光标上：本机用户刚移动过鼠标就重新对齐，
        // 否则会在旧位置误点。
        if EventTapMonitor.shared.lastLocalMouse > lastMoveAt {
            if let pos = CGEvent(source: nil)?.location { cursor = clamp(pos) }
        }
        guard let current = cursor ?? CGEvent(source: nil)?.location else { return }
        let type: CGEventType
        let cgButton: CGMouseButton
        if button == 2 {
            type = down ? .rightMouseDown : .rightMouseUp
            cgButton = .right
        } else {
            type = down ? .leftMouseDown : .leftMouseUp
            cgButton = .left
        }
        guard let event = CGEvent(mouseEventSource: source,
                                  mouseType: type,
                                  mouseCursorPosition: current,
                                  mouseButton: cgButton) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: EventTapMonitor.injectTag)
        event.post(tap: .cghidEventTap)
    }

    static func wheel(_ delta: Int) {
        guard delta != 0 else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: source,
                                  units: .line,
                                  wheelCount: 1,
                                  wheel1: Int32(delta),
                                  wheel2: 0,
                                  wheel3: 0) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: EventTapMonitor.injectTag)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - 收尾

    /// 对端断线或会话结束时松开所有按下的键，
    /// 否则本机会留下一个「永远按着」的修饰键。
    static func releaseAll() {
        let keys = pressedKeys
        pressedKeys.removeAll()
        flags = []
        for (vk, _) in keys {
            guard let code = KeyMap.macKeyCode(forVK: vk) else { continue }
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: CGKeyCode(code),
                                      keyDown: false) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: EventTapMonitor.injectTag)
            event.post(tap: .cghidEventTap)
        }
    }
}
