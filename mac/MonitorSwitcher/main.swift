import Cocoa
import ServiceManagement

/// 键鼠的工作方式
enum PointerMode: String {
    case independent    // 各自用各自的键鼠，不做任何转发
    case shared         // 键鼠跟随屏幕，两端都可作为输入源

    var title: String {
        switch self {
        case .independent: return "独立模式"
        case .shared:      return "共享模式"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private static let modeKey = "kvmbridge.pointerMode"
    private static let kbKey = "kvmbridge.shareKeyboard"
    private static let mouseKey = "kvmbridge.shareMouse"
    private static let autoStartKey = "kvmbridge.autoStart"

    private var statusItem: NSStatusItem!

    // 菜单只构建一次，之后原地改状态。
    // 早期版本每 3 秒换一个新 NSMenu，菜单开着时被替换会导致点击失效。
    private var menu: NSMenu!
    private var sourceItems: [Int: NSMenuItem] = [:]
    private var modeItems: [PointerMode: NSMenuItem] = [:]
    private var connItem: NSMenuItem!
    private var releaseItem: NSMenuItem!
    private var keyboardItem: NSMenuItem!
    private var mouseItem: NSMenuItem!
    private var headItem: NSMenuItem!
    private var portInfoItem: NSMenuItem!
    private var autoStartItem: NSMenuItem!

    /// 对端自报的操作系统与它所在的输入源值。断线即清空（无法识别时留空）。
    private(set) var peerOS: String?
    private(set) var peerMyValue: Int?

    // MARK: - 共享键鼠来源显示
    /// 共享模式下，当前生效的键盘/鼠标来自哪台设备（用 OS 名标识）。
    /// 只由「屏幕持有端」裁决并广播，两端菜单显示一致。
    private let useLock = NSLock()
    private var activeKeyboardOS: String?
    private var activeMouseOS: String?

    private var isScreenOwner: Bool { ownerValue == Ddc.myValue }

    /// 供菜单与诊断读取：事件泵线程会写这两个值，必须加锁。
    func useLabels() -> (kb: String?, mouse: String?) {
        useLock.lock(); defer { useLock.unlock() }
        return (activeKeyboardOS, activeMouseOS)
    }

    /// 本机真实输入 / 对端注入导致来源变化。只有真的变化才刷新菜单并广播。
    private func setUse(kb: String?, mouse: String?, broadcast: Bool) {
        useLock.lock()
        var changed = false
        if let k = kb, activeKeyboardOS != k { activeKeyboardOS = k; changed = true }
        if let m = mouse, activeMouseOS != m { activeMouseOS = m; changed = true }
        let snapshot = (activeKeyboardOS, activeMouseOS)
        useLock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in self?.refresh() }
        if broadcast, RelayServer.shared.hasClient {
            RelayServer.shared.sendLine("USE kb=\(snapshot.0 ?? "-") mouse=\(snapshot.1 ?? "-")")
        }
    }

    /// 收到持有端的裁决结果：原样同步（含清空），不再回播，避免环路。
    private func applyUseFromPeer(kb: String?, mouse: String?) {
        useLock.lock()
        let changed = (activeKeyboardOS != kb || activeMouseOS != mouse)
        activeKeyboardOS = kb
        activeMouseOS = mouse
        useLock.unlock()
        if changed { DispatchQueue.main.async { [weak self] in self?.refresh() } }
    }

    /// 断线 / 切到独立模式时清空，避免下次进入共享模式显示陈旧设备。
    private func clearUse() {
        useLock.lock()
        let changed = (activeKeyboardOS != nil || activeMouseOS != nil)
        activeKeyboardOS = nil
        activeMouseOS = nil
        useLock.unlock()
        if changed { DispatchQueue.main.async { [weak self] in self?.refresh() } }
    }

    private var displayKeeper: Process?
    private var cachedInput: Int?
    private var polling = false

    private static let ownerKey = "kvmbridge.owner"

    /// 屏幕归属的输入源值（15/16/17/18）。
    /// 只由「完成的切换」写入，绝不从 DDC 推断——这块屏对非活动端口
    /// 也会回自己的端口号，用 DDC 判断会导致截获/转发在两端反复错乱。
    var ownerValue: Int? {
        get { return UserDefaults.standard.object(forKey: Self.ownerKey) as? Int }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: Self.ownerKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.ownerKey)
            }
        }
    }
    /// 对端告知的屏幕归属（仅作兜底）
    var peerScreen: Int?

    /// 供诊断输出
    var modeName: String { return mode.rawValue }

    // 诊断计数：注入成功 / 因仲裁丢弃
    private(set) var injectedCount = 0
    private(set) var droppedCount = 0

    // 连续移动时的注入间隔：用来捕捉「指针突然冻住一下」的现象。
    /// 注入事件间隔超过 50ms 记为一次停顿
    private(set) var stalls = 0
    private(set) var maxInjectGapMs = 0
    private var lastInjectAt = Date.distantPast
    private var firstInjectAt = Date.distantPast

    /// 测量窗口：从第一条到最后一条鼠标事件的跨度
    var injectSpanMs: Int {
        guard firstInjectAt != .distantPast, lastInjectAt != .distantPast else { return 0 }
        return Int(lastInjectAt.timeIntervalSince(firstInjectAt) * 1000)
    }

    /// 开机自启偏好。默认开，保持此前行为；菜单勾选项直接改这个值。
    var autoStartEnabled: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Self.autoStartKey) as? Bool
            return v ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoStartKey) }
    }

    /// 由 App 自己在 Aqua 会话里注册/注销登录项。
    /// 外部 shell 调 launchctl bootstrap gui/<uid> 会被 I/O 错误拒绝（权限域限制），
    /// 因此不依赖 LaunchAgent plist 能否被加载。
    func applyAutoStart() {
        guard #available(macOS 13.0, *) else { return }
        let svc = SMAppService.mainApp
        if autoStartEnabled {
            if svc.status != .enabled {
                do { try svc.register() }
                catch { print("[Boot] login item register failed: \(error)") }
            }
        } else if svc.status != .notRegistered {
            do { try svc.unregister() }
            catch { print("[Boot] login item unregister failed: \(error)") }
        }
        print("[Boot] autoStart=\(autoStartEnabled) loginItem=\(loginItemStatus)")
    }

    /// 菜单点击与远程诊断共用：改偏好 → 同步系统登录项 → 刷新菜单勾选。
    func setAutoStart(_ on: Bool) {
        autoStartEnabled = on
        applyAutoStart()
        if menu != nil { refresh() }   // 启动阶段菜单尚未构建
    }

    @objc private func toggleAutoStart() {
        setAutoStart(!autoStartEnabled)
    }

    /// 供诊断接口读取
    var loginItemStatus: String {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:          return "enabled"
            case .notRegistered:    return "notRegistered"
            case .notFound:         return "notFound"
            case .requiresApproval: return "requiresApproval"
            @unknown default:       return "unknown"
            }
        }
        return "unsupported"
    }

    func resetStats() {
        injectedCount = 0
        droppedCount = 0
        stalls = 0
        maxInjectGapMs = 0
        lastInjectAt = .distantPast
        firstInjectAt = .distantPast
    }

    /// 仲裁开关。如果发现注入事件没有带上标记（tagged 一直为 0），
    /// 说明我们无法区分本地与远端，此时关掉仲裁，宁可失去「宿主优先」
    /// 也不能把远端事件当成本地输入全部丢掉。
    private var arbitrationEnabled = true

    /// 共享模式下，键盘与鼠标可以分别开关，便于逐项排查
    var shareKeyboard: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Self.kbKey) as? Bool
            return v ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.kbKey)
            EventTapMonitor.shared.forwardKeyboard = newValue
            applyMode()
        }
    }

    var shareMouse: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: Self.mouseKey) as? Bool
            return v ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.mouseKey)
            EventTapMonitor.shared.forwardMouse = newValue
            applyMode()
        }
    }

    private var mode: PointerMode {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.modeKey) ?? ""
            return PointerMode(rawValue: raw) ?? .independent
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.modeKey)
            applyMode()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例：开机自启 + 手动双击很容易出现两个进程，两个事件泵会互相抢输入。
        let peers = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.kvmbridge.app"
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        if !peers.isEmpty {
            NSApp.terminate(nil)
            return
        }

        startDisplayKeeper()
        applyAutoStart()
        // 启动阶段同步检测一次显示器能力与端口表，菜单一次构建到位。
        Ddc.detect()
        buildMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "KVM Bridge"
        statusItem.menu = menu

        NotificationCenter.default.addObserver(forName: Notification.Name("KVM.SetMode"),
                                               object: nil, queue: .main) { [weak self] note in
            guard let raw = note.object as? String,
                  let m = PointerMode(rawValue: raw) else { return }
            self?.mode = m
            self?.sendMode()
        }

        EventTapMonitor.shared.forwardKeyboard = shareKeyboard
        EventTapMonitor.shared.forwardMouse = shareMouse

        // 本机真实键鼠输入：只有屏幕在本机时由本机裁决来源并广播给对端。
        // 屏幕在对端时，本机是转发方，来源由对端（持有端）裁决后同步回来。
        EventTapMonitor.shared.onLocalInput = { [weak self] pointer in
            guard let self = self else { return }
            guard self.mode == .shared, self.isScreenOwner,
                  RelayServer.shared.hasClient else { return }
            self.setUse(kb: pointer ? nil : "macOS",
                        mouse: pointer ? "macOS" : nil,
                        broadcast: true)
        }

        setupRelay()
        // 局域网广播：让 Windows 端自动找到本机，不必手填 IP
        Discovery.shared.start()
        setupHotKeys()

        // 调试端口只在存在标记文件时开启，避免正式版常驻一个无鉴权的本地通道。
        // 需要诊断时：touch /tmp/kvm-debug.on 后重启 App。
        if FileManager.default.fileExists(atPath: "/tmp/kvm-debug.on") {
            DebugServer.shared.start()
        }

        refresh()
        // 不再定时轮询 DDC：菜单勾选只认协议归属，读数没有任何消费者，
        // 而每 2 秒 fork 一次 m1ddc 会持续占用 I2C，切屏刚完成时
        // 尤其容易打断显示器同步（表现为「无信号」和画面闪烁）。
        // 需要读数时由 menuWillOpen 按需读一次。
    }

    // MARK: - 菜单

    private func buildMenu() {
        menu = NSMenu()
        menu.delegate = self

        let head = NSMenuItem(title: "显示器 · " + Ddc.displayName, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        headItem = head
        menu.addItem(NSMenuItem.separator())

        let screenHeader = NSMenuItem(title: "屏幕输入源", action: nil, keyEquivalent: "")
        screenHeader.isEnabled = false
        menu.addItem(screenHeader)

        // 仅在显示器不支持 DDC/CI 时提示；支持时整行隐藏（不上报端口列表也算支持）。
        let info = NSMenuItem(title: Ddc.unsupportedText, action: nil, keyEquivalent: "")
        info.isEnabled = false
        info.indentationLevel = 1
        info.isHidden = Ddc.ddcAvailable
        menu.addItem(info)
        portInfoItem = info

        for src in Ddc.sources {
            let item = NSMenuItem(title: sourceTitle(src.name, src.value),
                                  action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = src.value
            item.indentationLevel = 1
            item.isEnabled = Ddc.ddcAvailable
            // 不设 keyEquivalent：⌃⌥1 / ⌃⌥2 由 Carbon 全局热键处理，
            // 两边都注册会在菜单打开时触发两次。
            sourceItems[src.value] = item
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let pointerHeader = NSMenuItem(title: "键鼠", action: nil, keyEquivalent: "")
        pointerHeader.isEnabled = false
        menu.addItem(pointerHeader)

        for m in [PointerMode.independent, PointerMode.shared] {
            let item = NSMenuItem(title: m.title, action: #selector(chooseMode(_:)), keyEquivalent: "")
            item.target = self
            item.indentationLevel = 1
            item.representedObject = m.rawValue
            modeItems[m] = item
            menu.addItem(item)
        }

        // 键盘 / 鼠标是共享模式的子项：独立模式下隐藏，共享模式下再缩进一级。
        let kbItem = NSMenuItem(title: "键盘", action: #selector(toggleKeyboard), keyEquivalent: "")
        kbItem.target = self
        kbItem.indentationLevel = 2
        kbItem.isHidden = (mode != .shared)
        menu.addItem(kbItem)
        keyboardItem = kbItem

        let msItem = NSMenuItem(title: "鼠标", action: #selector(toggleMouse), keyEquivalent: "")
        msItem.target = self
        msItem.indentationLevel = 2
        msItem.isHidden = (mode != .shared)
        menu.addItem(msItem)
        mouseItem = msItem

        menu.addItem(NSMenuItem.separator())

        connItem = NSMenuItem(title: "连接：等待 Windows", action: nil, keyEquivalent: "")
        connItem.isEnabled = false
        menu.addItem(connItem)

        releaseItem = NSMenuItem(title: "紧急释放", action: #selector(emergencyRelease), keyEquivalent: "")
        releaseItem.target = self
        releaseItem.isHidden = true
        menu.addItem(releaseItem)

        menu.addItem(NSMenuItem.separator())

        autoStartItem = NSMenuItem(title: "开机自启动", action: #selector(toggleAutoStart), keyEquivalent: "")
        autoStartItem.target = self
        menu.addItem(autoStartItem)

        let resetLink = NSMenuItem(title: "复位显示器连接", action: #selector(resetDisplayLink), keyEquivalent: "")
        resetLink.target = self
        menu.addItem(resetLink)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// 共享模式下在键盘/鼠标后面标出当前生效的是哪台设备的键鼠。
    /// 独立模式、断线、尚无任何输入时保持纯标题，不显示误导性标注。
    private func useItemTitle(_ base: String, os: String?) -> String {
        guard mode == .shared, let os = os, RelayServer.shared.hasClient else { return base }
        return base + " · " + os
    }

    private func refresh() {
        // 勾选只认协议确认的归属；DDC 读数对非活动端口会说谎。
        let owner = ownerValue
        headItem.title = "显示器 · " + Ddc.displayName
        portInfoItem.isHidden = Ddc.ddcAvailable
        for src in Ddc.sources {
            guard let item = sourceItems[src.value] else { continue }
            item.title = sourceTitle(src.name, src.value)
            item.state = (owner == src.value) ? .on : .off
            item.isEnabled = Ddc.ddcAvailable
        }
        for (m, item) in modeItems {
            item.state = (m == mode) ? .on : .off
        }
        keyboardItem.state = shareKeyboard ? .on : .off
        mouseItem.state = shareMouse ? .on : .off
        let use = useLabels()
        keyboardItem.title = useItemTitle("键盘", os: use.kb)
        mouseItem.title = useItemTitle("鼠标", os: use.mouse)
        autoStartItem.state = autoStartEnabled ? .on : .off
        // 独立模式下键鼠子项整行隐藏
        keyboardItem.isHidden = (mode != .shared)
        mouseItem.isHidden = (mode != .shared)

        let connected = RelayServer.shared.hasClient
        let forwarding = EventTapMonitor.shared.forwarding

        if !connected {
            // 断线原因要具体：网络不可达、心跳超时、对端退出，处理办法不同。
            connItem.title = "未连接 · " + RelayServer.shared.disconnectReason
        } else if forwarding {
            connItem.title = "已连接 · 键鼠已交出"
        } else {
            connItem.title = "已连接"
        }

        // 只有真正在转发时，「紧急释放」才有意义，平时不占位置
        releaseItem.isHidden = !forwarding
        releaseItem.isEnabled = forwarding

        statusItem.button?.appearsDisabled = SwitchFlow.shared.busy
    }

    /// 端口类型后面能识别到主机系统就显示，识别不到留空。
    private func osLabel(for value: Int) -> String {
        if value == Ddc.myValue { return "macOS" }
        if let pv = peerMyValue, pv == value, let os = peerOS { return os }
        return ""
    }

    private func sourceTitle(_ name: String, _ value: Int) -> String {
        let os = osLabel(for: value)
        return os.isEmpty ? name : name + " · " + os
    }

    /// 供调试接口输出菜单结构：缩进、隐藏、勾选、标题。
    func debugMenuSnapshot() -> String {
        guard let menu = menu else { return "no menu" }
        var lines: [String] = []
        for item in menu.items {
            if item.title.isEmpty { continue }   // 分隔项
            lines.append("[L\(item.indentationLevel)]"
                + (item.isHidden ? "HIDDEN " : "")
                + (item.state == .on ? "✓ " : "")
                + item.title)
        }
        return lines.joined(separator: " | ")
    }

    func menuWillOpen(_ menu: NSMenu) {
        poll()
        refresh()
    }

    // MARK: - 状态读取（只在菜单打开时按需执行）

    /// 读 DDC 要 fork 子进程（150~300ms），不能在主线程做，否则菜单会卡
    private func poll() {
        if polling { return }
        polling = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = Ddc.readInput()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.polling = false
                self.cachedInput = value

                // 本机读得到、而且读到的就是自己，说明屏幕明明在自己这边，
                // 绝不能继续把键鼠转发出去。对端广播的归属可能已经过时。
                // 只用 DDC 更新菜单勾选，不参与归属判定：
                // 这块屏会把自身端口号回给非活动端口，读到的值不可信。

                self.refresh()
            }
        }
    }

    // MARK: - 模式与转发

    private func applyMode() {
        switch mode {
        case .independent:
            // 独立模式：任何情况下都不转发
            clearUse()
            if EventTapMonitor.shared.forwarding {
                EventTapMonitor.shared.forwarding = false
            }
        case .shared:
            // 共享模式：如果屏幕已经在对端，把键鼠交过去。
            // 归属只认切换协议结果（ownerValue）；DDC 读数对非活动端口会说谎，
            // 用它判断会在断线重连后一直不转发，键盘鼠标看起来「完全没生效」。
            if ownerValue == Ddc.peerValue {
                startForwarding()
            }
        }
        refresh()
    }

    /// 开启转发。四个前提必须全部成立，缺一个都不能拦输入：
    /// 共享模式、屏幕在对端、对端在线且能注入、本机事件泵可用。
    private func startForwarding() {
        guard mode == .shared else { return }
        guard RelayServer.shared.hasClient else { return }
        // 只有「完成的切换」说屏幕在对端，才交出键鼠
        guard ownerValue == Ddc.peerValue else { return }
        guard RelayServer.shared.peerCanInject else {
            Toast.shared.show("对端无法注入键鼠，已保持本地输入")
            return
        }

        if !EventTapMonitor.shared.tapActive {
            _ = EventTapMonitor.shared.start()
        }
        guard EventTapMonitor.shared.tapActive else {
            // 这里绝不能把 forwarding 置 true：置了就等于「吞掉本地输入但发不出去」
            Toast.shared.show("辅助功能未授权，键鼠无法转发")
            sendCapability()
            return
        }

        if !EventTapMonitor.shared.forwarding {
            EventTapMonitor.shared.passThrough = true
            EventTapMonitor.shared.forwarding = true
            EventTapMonitor.shared.beginCapture()
        }
    }

    private func stopForwarding() {
        EventTapMonitor.shared.passThrough = false
        if EventTapMonitor.shared.forwarding {
            EventTapMonitor.shared.forwarding = false
            EventTapMonitor.shared.endCapture()
        }
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let m = PointerMode(rawValue: raw) else { return }
        mode = m
        sendMode()
        Toast.shared.show(m == .independent ? "已切换：独立模式" : "已切换：共享模式")
    }

    @objc private func toggleKeyboard() {
        shareKeyboard.toggle()
        sendMode()
        refresh()
    }

    @objc private func toggleMouse() {
        shareMouse.toggle()
        sendMode()
        refresh()
    }

    /// 把模式与分类开关同步给对端
    private func sendMode() {
        let kb = shareKeyboard ? 1 : 0
        let ms = shareMouse ? 1 : 0
        RelayServer.shared.sendLine("MODE \(mode.rawValue) kb=\(kb) mouse=\(ms)")
    }

    /// 本机能否注入键鼠（与事件泵同一个辅助功能权限）。
    /// 顺带上报屏幕逻辑尺寸：Windows 4K 是物理像素，Mac 是逻辑点，
    /// 对端据此把相对位移按比例换算，避免 2x 尺度差造成「光标飞走」。
    private func sendCapability() {
        let ok = EventTapMonitor.shared.isTrusted
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let w = Int(bounds.width), h = Int(bounds.height)
        RelayServer.shared.sendLine("CAP inject=\(ok ? 1 : 0) scr=\(w)x\(h)")
    }

    // MARK: - 对端消息

    private func handleLine(_ line: String) {
        if line.hasPrefix("K ") || line.hasPrefix("M ")
            || line.hasPrefix("B ") || line.hasPrefix("W ") {
            // 键鼠事件在读线程直接注入，不进主队列，少一跳延迟
            injectFromPeer(line)
            return
        }

        // 屏幕持有端裁决出的「当前正在用哪套键鼠」，两端实时同步显示。
        if line.hasPrefix("USE ") {
            var kb: String?
            var ms: String?
            for p in line.split(separator: " ").dropFirst() {
                if p.hasPrefix("kb=") {
                    let v = String(p.dropFirst(3))
                    kb = (v == "-" || v.isEmpty) ? nil : v
                } else if p.hasPrefix("mouse=") {
                    let v = String(p.dropFirst(6))
                    ms = (v == "-" || v.isEmpty) ? nil : v
                }
            }
            applyUseFromPeer(kb: kb, mouse: ms)
            return
        }

        if line.hasPrefix("CAP ") {
            RelayServer.shared.peerCanInject = line.contains("inject=1")
            if !RelayServer.shared.peerCanInject {
                stopForwarding()
            }
            return
        }

        // 对端自报操作系统和它所在的输入源值，用来在端口后面标注系统。
        // 识别不到（未连接、字段缺失）时 osLabel 会返回空，菜单保持纯端口名。
        if line.hasPrefix("HELLO ") {
            var os: String?
            var my: Int?
            for p in line.split(separator: " ").dropFirst() {
                if p.hasPrefix("os=") { os = String(p.dropFirst(3)) }
                if p.hasPrefix("my=") { my = Int(p.dropFirst(3)) }
            }
            peerOS = os?.isEmpty == false ? os : nil
            peerMyValue = my
            refresh()
            return
        }

        // 对端刚连上时索取归属。Mac 的持久化值只由「已确认的切换」写入，
        // 作为两端共识的基准，避免 Windows 用不可信的 DDC 读数反向下发。
        if line == "OWNER?" {
            if let v = ownerValue {
                RelayServer.shared.sendLine("OWNER \(v)")
            } else {
                RelayServer.shared.sendLine("OWNER -")
            }
            return
        }

        if line.hasPrefix("OWNER ") {
            let raw = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if raw == "-" {
                ownerValue = nil
                peerScreen = nil
                stopForwarding()
                Injector.releaseAll()
                clearUse()
                refresh()
                return
            }
            guard let value = Int(raw) else { return }
            peerScreen = value
            ownerValue = value

            if value == Ddc.peerValue {
                startForwarding()
            } else {
                stopForwarding()
            }
            // 屏幕切回本机：默认生效的是本机键鼠
            if value == Ddc.myValue, mode == .shared {
                setUse(kb: "macOS", mouse: "macOS", broadcast: true)
            }
            return
        }

        if line.hasPrefix("LATR ") {
            if let seq = Int(line.dropFirst(5)) {
                DebugServer.shared.recordLat(seq)
            }
            return
        }

        if line == "PING" {
            RelayServer.shared.sendLine("PONG")
            return
        }
        if line == "PONG" { return }

        if line.hasPrefix("MODE ") {
            let parts = line.split(separator: " ").map(String.init)
            var swapped = false
            if parts.count >= 2, let m = PointerMode(rawValue: parts[1]), m != mode {
                mode = m
                swapped = true
            }
            var kb = shareKeyboard
            var ms = shareMouse
            for p in parts.dropFirst(2) {
                if p.hasPrefix("kb=") { kb = p.hasSuffix("1") }
                if p.hasPrefix("mouse=") { ms = p.hasSuffix("1") }
            }
            if kb != shareKeyboard { shareKeyboard = kb }
            if ms != shareMouse { shareMouse = ms }
            if swapped {
                Toast.shared.show(mode == .independent ? "对端切换：独立模式" : "对端切换：共享模式")
            }
            applyMode()
            refresh()
            return
        }

        SwitchFlow.shared.handle(line)
    }

    /// 注入对端发来的键鼠事件（共享模式下、本机持有屏幕时）。
    ///
    /// 仲裁规则：两边同时操作时，当前屏幕持有端（本机）优先。
    /// 实现在最近 400ms 内有过真实本地输入时丢弃对端事件——
    /// 本地输入不经网络，天然更快；丢弃远端就能避免两套输入打架。
    private func injectFromPeer(_ line: String) {
        guard mode == .shared, !EventTapMonitor.shared.forwarding else { return }

        if arbitrationEnabled {
            // 自检：注入了足够多的事件却一次都没在事件泵里看到标记，
            // 说明标记机制失效，仲裁会误杀远端事件，直接关掉。
            if injectedCount >= 100 && EventTapMonitor.shared.taggedCount == 0 {
                arbitrationEnabled = false
                print("[Inject] tag not visible in tap, arbitration disabled")
            } else {
                // 键盘和鼠标分开仲裁：本机打字不该挡住对端的鼠标事件，
                // 本机晃鼠标也不该让对端打字丢失。
                let peerIsPointer = line.hasPrefix("M ") || line.hasPrefix("B ") || line.hasPrefix("W ")
                let last = peerIsPointer ? EventTapMonitor.shared.lastLocalMouse
                                         : EventTapMonitor.shared.lastLocalKeyboard
                let idle = Date().timeIntervalSince(last)
                if idle <= EventTapMonitor.localPriorityWindow {
                    droppedCount += 1
                    return
                }
            }
        }
        injectedCount += 1

        // 屏幕在本机、且成功注入了对端事件 → 当前生效的是对端那套键鼠。
        // 键盘与鼠标分别记录；值没变时 setUse 会立即返回，不会每帧广播。
        if isScreenOwner {
            let os = peerOS ?? "Windows"
            if line.hasPrefix("K ") {
                setUse(kb: os, mouse: nil, broadcast: true)
            } else {
                setUse(kb: nil, mouse: os, broadcast: true)
            }
        }

        if line.hasPrefix("M ") {
            let now = Date()
            if firstInjectAt == .distantPast { firstInjectAt = now }
            if lastInjectAt != .distantPast {
                let gap = now.timeIntervalSince(lastInjectAt) * 1000
                // 50–400ms 视作卡顿；更长的间隔多半是用户自己停手
                if gap > 50 && gap < 400 { stalls += 1 }
                if Int(gap) > maxInjectGapMs { maxInjectGapMs = Int(gap) }
            }
            lastInjectAt = now
        }

        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return }

        switch parts[0] {
        case "K":
            guard shareKeyboard else { return }
            guard parts.count >= 3, let vk = UInt16(parts[1]) else { return }
            Injector.key(vk: vk, down: parts[2] == "1")
        case "M":
            guard shareMouse else { return }
            guard parts.count >= 3, let dx = Int(parts[1]), let dy = Int(parts[2]) else { return }
            Injector.mouseMove(dx: dx, dy: dy)
        case "B":
            guard shareMouse else { return }
            guard parts.count >= 3, let button = Int(parts[1]) else { return }
            Injector.mouseButton(button, down: parts[2] == "1")
        case "W":
            guard shareMouse else { return }
            guard let delta = Int(parts[1]) else { return }
            Injector.wheel(delta)
        default:
            break
        }
    }

    // MARK: - 连接与流程

    private func setupRelay() {
        RelayServer.shared.onClientChange = { [weak self] connected in
            guard let self = self else { return }
            if connected {
                self.clearUse()   // 重连后重新裁决，不显示断线前的旧设备
                self.sendMode()
                // 屏幕在本机时，默认生效的是本机键鼠，先给两端一个明确标注
                if self.mode == .shared, self.isScreenOwner {
                    self.setUse(kb: "macOS", mouse: "macOS", broadcast: true)
                }
                self.sendCapability()
                RelayServer.shared.sendLine("HELLO os=macOS my=\(Ddc.myValue)")
                if let v = self.ownerValue {
                    RelayServer.shared.sendLine("OWNER \(v)")
                } else {
                    RelayServer.shared.sendLine("OWNER -")
                }
                // 对端刚连上，如果屏幕本来就在它那边，直接交出键鼠。
                // ownerValue 只由「已确认的切换」或已确认的对端广播写入，
                // 离线盲切不会污染它，因此重连瞬间可以安全恢复，无需等握手。
                if self.mode == .shared, self.ownerValue == Ddc.peerValue {
                    self.startForwarding()
                }
            } else {
                // 断线后不再知道对端系统，端口后面的系统标注要留空
                self.peerOS = nil
                self.peerMyValue = nil
                self.clearUse()
                // 转发中掉线必须立刻释放，否则输入被吃掉却送不出去
                if EventTapMonitor.shared.forwarding {
                    self.stopForwarding()
                    Toast.shared.show("与 Windows 的连接断开，键鼠已收回")
                }
                Injector.releaseAll()
            }
            self.refresh()
        }

        RelayServer.shared.onLine = { [weak self] line in
            guard let self = self else { return }
            if line.hasPrefix("K ") || line.hasPrefix("M ")
                || line.hasPrefix("B ") || line.hasPrefix("W ") {
                self.injectFromPeer(line)
            } else {
                DispatchQueue.main.async { self.handleLine(line) }
            }
        }

        _ = RelayServer.shared.start()

        SwitchFlow.shared.onUpdate = { [weak self] in
            self?.refresh()
        }

        SwitchFlow.shared.onOwnerChange = { [weak self] owner in
            self?.apply(owner: owner)
        }

        EventTapMonitor.shared.onEmergencyRelease = { [weak self] in
            EventTapMonitor.shared.forwarding = false
            Toast.shared.show("已紧急释放：键鼠回到本机")
            self?.refresh()
        }

        // 事件泵常驻启动（只观测，不拦截）；转发开关只管是否消费事件
        _ = EventTapMonitor.shared.start()
    }

    /// 屏幕归属确定之后才动键鼠，且只在共享模式下转发
    private func apply(owner: ScreenOwner) {
        // 归属未确认（典型场景：对端离线时的盲切）时，既不写持久化缓存，
        // 也不向对端广播——不能把一个没有验证过的值扩散成两端共识。
        if case .unknown = owner {
            // 归属不再可信：清掉持久化缓存并广播「未知」，让对端也释放
            // 本机键鼠。否则对端会沿用旧归属继续吞掉本地输入，
            // 表现为「有画面但鼠标完全不动」。
            ownerValue = nil
            peerScreen = nil
            RelayServer.shared.sendLine("OWNER -")
            stopForwarding()
            Injector.releaseAll()
            sendCapability()
            refresh()
            return
        }

        switch owner {
        case .me:        ownerValue = Ddc.myValue
        case .peer:      ownerValue = Ddc.peerValue
        case .third(let v): ownerValue = v
        case .unknown:   break
        }

        if let v = ownerValue {
            RelayServer.shared.sendLine("OWNER \(v)")
        }

        switch owner {
        case .peer where mode == .shared:
            startForwarding()
        default:
            stopForwarding()
            Injector.releaseAll()
        }
        // 每次切换后同步一次能力：授权状态可能被用户中途改掉
        sendCapability()
        refresh()
    }

    private func setupHotKeys() {
        HotKeys.shared.onTrigger = { target in
            SwitchFlow.shared.requestSwitch(to: target)
        }
        HotKeys.shared.register()
    }

    /// 保持显示管道活跃，避免切回时显示器判定无信号
    private func startDisplayKeeper() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-d", "-i"]
        do {
            try p.run()
            displayKeeper = p
        } catch {
            displayKeeper = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopForwarding()
        Injector.releaseAll()
        displayKeeper?.terminate()
    }

    // MARK: - 动作

    @objc private func choose(_ sender: NSMenuItem) {
        SwitchFlow.shared.requestSwitch(to: sender.tag)
    }

    @objc private func emergencyRelease() {
        stopForwarding()
        Toast.shared.show("已紧急释放：键鼠回到本机")
        refresh()
    }

    /// 显示器 DDC 从设备掉线时（读回噪声、切屏后无信号）手动复位一次。
    /// 让显示器睡眠再唤醒，scaler 会重新初始化 DDC/CI，实测 2 秒内恢复读数。
    @objc private func resetDisplayLink() {
        Toast.shared.show("正在复位显示器连接…")
        DispatchQueue.global(qos: .utility).async {
            Ddc.resetChannel(force: true)
            DispatchQueue.main.async {
                Toast.shared.show("显示器连接已复位，可重新切换屏幕")
                self.refresh()
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
