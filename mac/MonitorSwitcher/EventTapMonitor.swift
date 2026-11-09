import Cocoa
import CoreGraphics
import ApplicationServices

/// 事件泵：常驻监听键鼠事件。
/// - 转发开启时消耗事件并发送到对端
/// - 关闭时所有事件原样放行，系统行为不受影响
/// - 自己注入的事件带标记，直接放行，避免回环
final class EventTapMonitor {

    static let shared = EventTapMonitor()

    /// 注入事件的标记值。事件泵据此判断「这是对端发来的」，
    /// 既不回传也不计入本地活动——这是防回环和输入仲裁的基础。
    static let injectTag: Int64 = 0x4B56_4D42   // 'KVMB'

    /// 本地输入优先窗口：屏幕持有端在本机时，这段时间内丢弃对端注入，
    /// 实现「两边同时动，优先当前屏幕宿主」。
    static let localPriorityWindow: TimeInterval = 0.4

    let logPath = "/tmp/kvm-tap.log"

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fileHandle: FileHandle?
    private let formatter: DateFormatter

    private(set) var tapActive = false
    private(set) var capturing = false
    private(set) var eventCount = 0
    private(set) var keyCount = 0

    /// 最近一次真实本地输入的时间（不含注入事件），供仲裁使用
    private(set) var lastLocalInput = Date.distantPast
    /// 键盘与鼠标分开记录：本机打字不该挡住对端的鼠标，反之亦然。
    private(set) var lastLocalMouse = Date.distantPast
    private(set) var lastLocalKeyboard = Date.distantPast

    /// 转发模式：开启后键盘与鼠标事件被拦截并发送到对端。
    /// 关闭时会补发所有按下的键/按钮，避免对端出现卡键。
    var forwarding = false {
        didSet {
            guard forwarding != oldValue else { return }
            if forwarding {
                startFlushTimer()
            } else {
                stopFlushTimer()
                releaseAll()
            }
        }
    }

    /// 紧急释放回调：无论处于什么状态，⌃⌥⎋ 都能强制复位
    /// 共享模式下按类别开关，便于逐项排查
    var forwardKeyboard = true
    var forwardMouse = true
    /// 转发的同时把本机事件放行（与 Windows 端对等），避免本机键鼠被吞掉。
    var passThrough = false
    var onEmergencyRelease: (() -> Void)?

    /// 真实本地输入（不含自己注入的）发生时通知上层，用于共享模式下
    /// 在菜单里显示「当前正在用哪套键鼠」。Bool = 是否为指针类事件。
    /// 回调在事件泵线程上高频触发，实现必须只做轻量比较。
    var onLocalInput: ((Bool) -> Void)?

    private(set) var mouseMessages = 0
    private(set) var seenMoves = 0
    private(set) var seenKeys = 0
    private(set) var forwardedKeys = 0
    /// 事件泵看到的「自己注入」的事件数。用于确认标记没有在注入后被系统抹掉。
    private(set) var taggedCount = 0

    private var pendingDX: Int64 = 0
    private var pendingDY: Int64 = 0
    private let pendingLock = NSLock()
    private var flushTimer: DispatchSourceTimer?

    /// 已按下（且已转发）的 macOS 键码，转发中止时全部补发 keyUp
    private var pressedKeys: Set<Int64> = []
    /// 已按下的鼠标键
    private var pressedButtons: Set<Int> = []
    /// 修饰键状态。.flagsChanged 每来一次就翻转该键的状态，
    /// 这样左右 Shift 同时按住也不会互相干扰。
    private var modifierDown: [Int64: Bool] = [:]

    // macOS 虚拟键码
    private let kc1: Int64 = 18      // 数字 1
    private let kc2: Int64 = 19      // 数字 2
    private let kcEsc: Int64 = 53    // Esc

    private init() {
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
    }

    // MARK: - 权限

    var isTrusted: Bool {
        return AXIsProcessTrusted()
    }

    @discardableResult
    func requestPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - 日志

    private func openLog() {
        FileManager.default.createFile(atPath: logPath, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: logPath)
        fileHandle?.truncateFile(atOffset: 0)
        fileHandle?.seekToEndOfFile()
    }

    private func closeLog() {
        fileHandle?.closeFile()
        fileHandle = nil
    }

    private func write(_ text: String) {
        guard let fh = fileHandle, let data = (text + "\n").data(using: .utf8) else { return }
        fh.seekToEndOfFile()
        fh.write(data)
    }

    private func stamp() -> String {
        return formatter.string(from: Date())
    }

    // MARK: - 鼠标位移合并

    /// 鼠标移动频率可达 125–1000Hz，逐个发送会产生大量小包。
    /// 按 4ms 窗口合并（250Hz），既压掉碎包，又不至于被感知成延迟。
    private func startFlushTimer() {
        stopFlushTimer()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            self?.flushMouse()
        }
        timer.resume()
        flushTimer = timer
    }

    private func stopFlushTimer() {
        flushTimer?.cancel()
        flushTimer = nil
        pendingLock.lock()
        pendingDX = 0
        pendingDY = 0
        pendingLock.unlock()
    }

    private func flushMouse() {
        pendingLock.lock()
        let dx = pendingDX
        let dy = pendingDY
        pendingDX = 0
        pendingDY = 0
        pendingLock.unlock()

        if dx == 0 && dy == 0 { return }
        mouseMessages += 1
        RelayServer.shared.sendLine("M \(dx) \(dy)")
    }

    // MARK: - 按键状态

    private func trackKey(_ keycode: Int64, down: Bool) {
        if down {
            pressedKeys.insert(keycode)
        } else {
            pressedKeys.remove(keycode)
        }
    }

    /// 转发中止时把「还按着的键」全部松开。
    /// 不做这一步的话，按住 Shift 切屏会让对端的 Shift 永久卡住。
    private func releaseAll() {
        let keys = pressedKeys
        let buttons = pressedButtons
        pressedKeys.removeAll()
        pressedButtons.removeAll()
        modifierDown.removeAll()

        for kc in keys {
            if let vk = KeyMap.vk(for: kc) {
                RelayServer.shared.sendLine("K \(vk) 0")
            }
        }
        for b in buttons {
            RelayServer.shared.sendLine("B \(b) 0")
        }
    }

    // MARK: - 启停

    /// 常驻启动，幂等
    @discardableResult
    func start() -> Bool {
        if tapActive { return true }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .defaultTap,
                                             eventsOfInterest: mask,
                                             callback: eventTapCallback,
                                             userInfo: refcon) else {
            tapActive = false
            return false
        }

        tap = newTap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        if let src = source {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        CGEvent.tapEnable(tap: newTap, enable: true)
        tapActive = true
        return true
    }

    func stop() {
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            if let src = source {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
            }
        }
        tap = nil
        source = nil
        tapActive = false
        capturing = false
        forwarding = false
        closeLog()
    }

    // MARK: - 捕获（调试）

    func beginCapture() {
        guard tapActive else { return }
        openLog()
        eventCount = 0
        keyCount = 0
        capturing = true
        write("=== capture start \(stamp()) trusted=\(isTrusted) ===")
    }

    func endCapture() {
        capturing = false
        write("=== capture end \(stamp()) events=\(eventCount) keys=\(keyCount) ===")
        closeLog()
    }

    // MARK: - 事件处理

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap {
                CGEvent.tapEnable(tap: t, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // 自己注入的事件：原样放行。既不计为本地输入（否则仲裁会自杀），
        // 也绝不回传给对端（否则两端互相喂事件形成雪崩）。
        if event.getIntegerValueField(.eventSourceUserData) == EventTapMonitor.injectTag {
            taggedCount += 1
            return Unmanaged.passUnretained(event)
        }

        var pointer = false
        var keyboard = false
        switch type {
        case .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .scrollWheel:
            seenMoves += 1
            pointer = true
        case .keyDown:
            seenKeys += 1
            keyboard = true
        case .keyUp, .flagsChanged:
            keyboard = true
        default:
            break
        }

        // 到这里一定是真实本地输入
        let now = Date()
        lastLocalInput = now
        if pointer { lastLocalMouse = now }
        if keyboard { lastLocalKeyboard = now }
        onLocalInput?(pointer)

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // 紧急释放 ⌃⌥⎋：最高优先级，不依赖网络。
        // 这是输入被拦截后唯一的本地逃生口。
        if type == .keyDown && keycode == 53
            && flags.contains(.maskControl) && flags.contains(.maskAlternate) {
            forwarding = false
            DispatchQueue.main.async { [weak self] in
                self?.onEmergencyRelease?()
            }
            return nil
        }

        // ⌃⌥1 / ⌃⌥2 平时交给 Carbon 处理（不依赖辅助功能授权）。
        // 但转发开启时事件会被下面整段消费掉，Carbon 收不到，
        // 所以转发期间必须在事件泵里自己识别，否则热键就失效了。
        if forwarding && type == .keyDown
            && flags.contains(.maskControl) && flags.contains(.maskAlternate)
            && (keycode == kc1 || keycode == kc2) {
            let target = (keycode == kc1) ? Ddc.myValue : Ddc.peerValue
            DispatchQueue.main.async {
                SwitchFlow.shared.requestSwitch(to: target)
            }
            return nil
        }

        // 转发模式：键盘事件拦截并发送
        if forwarding && forwardKeyboard {
            switch type {
            case .keyDown, .keyUp:
                if let vk = KeyMap.vk(for: keycode) {
                    let down = (type == .keyDown)
                    forwardedKeys += 1
                    trackKey(keycode, down: down)
                    RelayServer.shared.sendLine("K \(vk) \(down ? 1 : 0)")
                    if capturing {
                        write("\(stamp()) FORWARD vk=0x\(String(format: "%02X", vk)) down=\(down ? 1 : 0)")
                    }
                }
                return passThrough ? Unmanaged.passUnretained(event) : nil

            case .flagsChanged:
                // 修饰键在 macOS 上是 .flagsChanged，不是 keyDown/keyUp。
                // 少了这一支，Ctrl/Shift/Option/Cmd 永远到不了对端，组合键全部失效。
                let down = !(modifierDown[keycode] ?? false)
                modifierDown[keycode] = down
                if let vk = KeyMap.vk(for: keycode) {
                    forwardedKeys += 1
                    trackKey(keycode, down: down)
                    RelayServer.shared.sendLine("K \(vk) \(down ? 1 : 0)")
                }
                return passThrough ? Unmanaged.passUnretained(event) : nil

            default:
                break
            }
        }

        // 转发模式：鼠标移动。起步立即发，连续移动进 4ms 合并窗口。
        if forwarding && forwardMouse && (type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged) {
            let dx = event.getIntegerValueField(.mouseEventDeltaX)
            let dy = event.getIntegerValueField(.mouseEventDeltaY)

            pendingLock.lock()
            let idle = (pendingDX == 0 && pendingDY == 0)
            if idle {
                pendingLock.unlock()
                mouseMessages += 1
                RelayServer.shared.sendLine("M \(dx) \(dy)")
            } else {
                pendingDX += dx
                pendingDY += dy
                pendingLock.unlock()
            }
            return passThrough ? Unmanaged.passUnretained(event) : nil
        }

        if forwarding && forwardMouse && (type == .leftMouseDown || type == .leftMouseUp
                                          || type == .rightMouseDown || type == .rightMouseUp) {
            var button = 1
            var down = true
            switch type {
            case .leftMouseDown:
                button = 1
                down = true
            case .leftMouseUp:
                button = 1
                down = false
            case .rightMouseDown:
                button = 2
                down = true
            default:
                button = 2
                down = false
            }
            if down { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
            RelayServer.shared.sendLine("B \(button) \(down ? 1 : 0)")
            return passThrough ? Unmanaged.passUnretained(event) : nil
        }

        if forwarding && forwardMouse && type == .scrollWheel {
            let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            RelayServer.shared.sendLine("W \(delta)")
            return passThrough ? Unmanaged.passUnretained(event) : nil
        }

        if capturing {
            eventCount += 1
            switch type {
            case .keyDown:
                keyCount += 1
                write("\(stamp()) DOWN code=\(keycode) flags=\(event.flagDescription)")
            case .keyUp:
                write("\(stamp()) UP   code=\(keycode)")
            case .flagsChanged:
                write("\(stamp()) FLAG code=\(keycode) flags=\(event.flagDescription)")
            case .leftMouseDown:
                write("\(stamp()) LMB down")
            case .leftMouseUp:
                write("\(stamp()) LMB up")
            case .rightMouseDown:
                write("\(stamp()) RMB down")
            case .rightMouseUp:
                write("\(stamp()) RMB up")
            case .scrollWheel:
                write("\(stamp()) SCROLL \(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))")
            default:
                break
            }
        }

        return Unmanaged.passUnretained(event)
    }
}

private let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
    guard let refcon = refcon else {
        return Unmanaged.passUnretained(event)
    }
    let monitor = Unmanaged<EventTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}

extension CGEvent {
    var flagDescription: String {
        var parts: [String] = []
        let f = self.flags
        if f.contains(.maskShift) { parts.append("shift") }
        if f.contains(.maskControl) { parts.append("ctrl") }
        if f.contains(.maskAlternate) { parts.append("opt") }
        if f.contains(.maskCommand) { parts.append("cmd") }
        if f.contains(.maskSecondaryFn) { parts.append("fn") }
        return parts.isEmpty ? "-" : parts.joined(separator: "+")
    }
}
