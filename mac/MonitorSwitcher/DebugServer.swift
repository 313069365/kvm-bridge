import Cocoa
import Foundation
import Darwin

/// 只监听 127.0.0.1 的调试通道，用来在没有键盘输入的情况下驱动一次切换。
/// 用法：
///   echo 16 | nc 127.0.0.1 24901    切到 Windows
///   echo 15 | nc 127.0.0.1 24901    切到 Mac
///   echo status | nc 127.0.0.1 24901
final class DebugServer {

    static let shared = DebugServer()

    private var fd: Int32 = -1
    private let port: UInt16 = 24901

    // 往返延迟测量
    private var latSent: [Int: Date] = [:]
    private var latRTTs: [Double] = []
    private let latLock = NSLock()

    /// 对端回了延迟探测
    func recordLat(_ seq: Int) {
        latLock.lock()
        if let sent = latSent.removeValue(forKey: seq) {
            latRTTs.append(Date().timeIntervalSince(sent) * 1000)
        }
        latLock.unlock()
    }

    func start() {
        guard fd < 0 else { return }

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        if sock < 0 { return }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(sock, 2) == 0 else {
            close(sock)
            print("[Debug] bind 127.0.0.1:\(port) failed")
            return
        }

        fd = sock
        print("[Debug] listening on 127.0.0.1:\(port)")

        let thread = Thread { [weak self] in
            self?.loop()
        }
        thread.stackSize = 256 * 1024
        thread.start()
    }

    private func loop() {
        while true {
            let listenFD = fd
            if listenFD < 0 { return }

            var clientAddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let cfd = Darwin.accept(listenFD, &clientAddr, &len)
            if cfd < 0 { return }

            var buffer = [UInt8](repeating: 0, count: 256)
            let n = Darwin.read(cfd, &buffer, buffer.count)
            if n <= 0 {
                close(cfd)
                continue
            }

            let text = String(bytes: buffer[0..<n], encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let reply = handle(text)
            let data = Array((reply + "\n").utf8)
            _ = data.withUnsafeBufferPointer { buf in
                Darwin.write(cfd, buf.baseAddress, buf.count)
            }
            close(cfd)
        }
    }

    private func handle(_ text: String) -> String {
        print("[Debug] command: \(text)")

        // 向 Windows 发任意一行协议报文，用于自动化测试两端链路
        if text.hasPrefix("send ") {
            let line = String(text.dropFirst(5))
            RelayServer.shared.sendLine(line)
            return "sent: \(line)"
        }

        // burst <条数> <间隔微秒>：按给定节拍压测 Mac→Windows 方向
        if text.hasPrefix("burst ") {
            let p = text.split(separator: " ").map(String.init)
            let n = p.count > 1 ? (Int(p[1]) ?? 0) : 0
            let gap = p.count > 2 ? (Int(p[2]) ?? 0) : 0
            let count = min(max(n, 0), 2000)
            DispatchQueue.global().async {
                for _ in 0..<count {
                    RelayServer.shared.sendLine("M 3 2")
                    if gap > 0 { usleep(UInt32(gap)) }
                }
            }
            return "burst \(count) gap=\(gap)us"
        }

        // inject <dx> <dy>：本机直接注入一次相对位移并回报光标位置，
        // 用来验证虚拟坐标在屏幕边缘不会漂移（无需 Windows 参与）。
        if text.hasPrefix("inject ") {
            let p = text.split(separator: " ").map(String.init)
            let dx = p.count > 1 ? (Int(p[1]) ?? 0) : 0
            let dy = p.count > 2 ? (Int(p[2]) ?? 0) : 0
            Injector.mouseMove(dx: dx, dy: dy)
            let pos = CGEvent(source: nil)?.location ?? .zero
            return String(format: "cursor=(%.0f,%.0f)", pos.x, pos.y)
        }

        // ddclog：列出最近的 DDC 0x60 写操作，用来确认一次切屏只有一次写、两端没有互写
        if text == "ddclog" {
            let log = Ddc.writeLog
            return log.isEmpty ? "no writes" : log
        }

        // injectburst <帧数> <dx> <dy> <间隔微秒>：连续注入，回报起止光标。
        // 用来验证「连续注入期间不回读系统光标」后位移是线性的、不会跳回旧位置。
        if text.hasPrefix("injectburst ") {
            let p = text.split(separator: " ").map(String.init)
            let n = min(max(p.count > 1 ? (Int(p[1]) ?? 0) : 0, 0), 500)
            let dx = p.count > 2 ? (Int(p[2]) ?? 0) : 0
            let dy = p.count > 3 ? (Int(p[3]) ?? 0) : 0
            let gap = p.count > 4 ? (Int(p[4]) ?? 0) : 0
            let start = CGEvent(source: nil)?.location ?? .zero
            for _ in 0..<n {
                Injector.mouseMove(dx: dx, dy: dy)
                if gap > 0 { usleep(UInt32(gap)) }
            }
            usleep(150000)   // 等异步 CGEventPost 落地
            let end = CGEvent(source: nil)?.location ?? .zero
            return String(format: "start=(%.0f,%.0f) end=(%.0f,%.0f) expect=(%.0f,%.0f) n=%d",
                          start.x, start.y, end.x, end.y,
                          start.x + CGFloat(dx * n), start.y + CGFloat(dy * n), n)
        }

        // menu：输出菜单结构，便于自动化验证布局（无需截图）
        if text == "menu" {
            let app = NSApplication.shared.delegate as? AppDelegate
            return app?.debugMenuSnapshot() ?? "no app"
        }

        // boot on/off：与菜单点击同一条路径，便于远程验证自启勾选
        if text == "boot on" || text == "boot off" {
            let on = (text == "boot on")
            let app = NSApplication.shared.delegate as? AppDelegate
            app?.setAutoStart(on)
            return "autoStart=\(on) loginItem=\(app?.loginItemStatus ?? "?")"
        }

        // plan <输入源>：只判断切换路径，不写 DDC（安全，不会真的切屏）
        if text == "plan" || text.hasPrefix("plan ") {
            let p = text.split(separator: " ").map(String.init)
            let v = p.count > 1 ? (Int(p[1]) ?? Ddc.peerValue) : Ddc.peerValue
            return SwitchFlow.shared.describe(target: v)
        }

        switch text {
        case "15", "switch 15":
            SwitchFlow.shared.requestSwitch(to: Ddc.myValue)
            return "ok 15"

        case "16", "switch 16":
            SwitchFlow.shared.requestSwitch(to: Ddc.peerValue)
            return "ok 16"

        case "status":
            let input = Ddc.readInput()
            let m = EventTapMonitor.shared
            let app = NSApplication.shared.delegate as? AppDelegate
            let parts: [String] = [
                "input=" + (input.map(String.init) ?? "nil"),
                "busy=\(SwitchFlow.shared.busy)",
                "fwd=\(m.forwarding)",
                "trusted=\(m.isTrusted)",
                "tap=\(m.tapActive)",
                "keys=\(m.forwardedKeys)",
                "mouseMsgs=\(m.mouseMessages)",
                "seenKeys=\(m.seenKeys)",
                "seenMoves=\(m.seenMoves)",
                "tagged=\(m.taggedCount)",
                "mode=" + (app?.modeName ?? "?"),
                "loginItem=" + (app?.loginItemStatus ?? "?"),
                "autoStart=" + String(app?.autoStartEnabled ?? true),
                "display=" + Ddc.displayName,
                "ddcOK=" + String(Ddc.ddcAvailable),
                "ports=" + String(Ddc.portsDetected),
                "peerOS=" + (app?.peerOS ?? "-"),
                "kb=" + String(app?.shareKeyboard ?? true),
                "mouse=" + String(app?.shareMouse ?? true),
                "peerScreen=" + (app?.peerScreen.map(String.init) ?? "nil"),
                "owner=" + (app?.ownerValue.map(String.init) ?? "nil"),
                "client=\(RelayServer.shared.hasClient)",
                "discWin=" + (Discovery.shared.peerIP.isEmpty ? "-" : Discovery.shared.peerIP),
                "scr=\(Int(CGDisplayBounds(CGMainDisplayID()).width))x\(Int(CGDisplayBounds(CGMainDisplayID()).height))",
                "ddcw=" + (Ddc.writeLog.isEmpty ? "-" : Ddc.writeLog),
                "peerCap=\(RelayServer.shared.peerCanInject)",
                "injected=\(app?.injectedCount ?? 0)",
                "dropped=\(app?.droppedCount ?? 0)",
                "stalls=\(app?.stalls ?? 0)",
                "gapmax=\(app?.maxInjectGapMs ?? 0)ms",
                "span=\(app?.injectSpanMs ?? 0)ms",
                "status=" + SwitchFlow.shared.status
            ]
            return parts.joined(separator: " ")

        case "mode shared":
            NotificationCenter.default.post(name: Notification.Name("KVM.SetMode"),
                                            object: PointerMode.shared.rawValue)
            return "mode shared"

        case "mode independent":
            NotificationCenter.default.post(name: Notification.Name("KVM.SetMode"),
                                            object: PointerMode.independent.rawValue)
            return "mode independent"

        case "reset":
            (NSApplication.shared.delegate as? AppDelegate)?.resetStats()
            return "reset ok"

        case "rate":
            // 采样 3 秒，看实际注入/转发速率。用于判断是「事件没到」还是「到了但太多」
            let app = NSApplication.shared.delegate as? AppDelegate
            let i0 = app?.injectedCount ?? 0
            let d0 = app?.droppedCount ?? 0
            let m0 = EventTapMonitor.shared.mouseMessages
            Thread.sleep(forTimeInterval: 3.0)
            let i1 = app?.injectedCount ?? 0
            let d1 = app?.droppedCount ?? 0
            let m1 = EventTapMonitor.shared.mouseMessages
            return "rate: injected +\(i1 - i0) dropped +\(d1 - d0) forwarded +\(m1 - m0) over 3s"

        case "lat":
            latLock.lock()
            latSent.removeAll()
            latRTTs.removeAll()
            latLock.unlock()

            for i in 0..<12 {
                latLock.lock()
                latSent[i] = Date()
                latLock.unlock()
                RelayServer.shared.sendLine("LAT \(i)")
                Thread.sleep(forTimeInterval: 0.05)
            }
            Thread.sleep(forTimeInterval: 0.8)

            latLock.lock()
            let rtts = latRTTs.sorted()
            latLock.unlock()
            if rtts.isEmpty { return "lat: no reply (peer not connected?)" }
            let avg = rtts.reduce(0, +) / Double(rtts.count)
            return String(format: "lat n=%d avg=%.1fms min=%.1f max=%.1f",
                          rtts.count, avg, rtts.first ?? 0, rtts.last ?? 0)

        case "perf":
            // 量化注入开销：500 次鼠标移动用多少毫秒
            let start = Date()
            for _ in 0..<500 { Injector.mouseMove(dx: 1, dy: 0) }
            let ms = Date().timeIntervalSince(start) * 1000
            return String(format: "500 moves in %.0f ms (%.2f ms/event)", ms, ms / 500)

        case "kickoff":
            DisplayKick.enabled = false
            return "kick off"

        case "kickon":
            DisplayKick.enabled = true
            return "kick on"

        default:
            return "unknown"
        }
    }
}
