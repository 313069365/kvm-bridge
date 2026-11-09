import Foundation

/// m1ddc 的命令行封装。所有 DDC 读写都经它转发，
/// 这样切换流程、菜单、热键用的是同一套语义。
enum Ddc {

    /// 正式包用 App bundle 内的 m1ddc；源码树调试时按相对目录或环境变量查找。
    /// 不写死任何本机绝对路径，否则安装包换台机器就失效。
    static var binary: String {
        if let p = Bundle.main.path(forResource: "m1ddc", ofType: nil),
           FileManager.default.isExecutableFile(atPath: p) { return p }
        if let p = ProcessInfo.processInfo.environment["M1DDC_PATH"],
           FileManager.default.isExecutableFile(atPath: p) { return p }
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<5 {
            let cand = dir.appendingPathComponent("vendor/m1ddc/m1ddc").path
            if FileManager.default.isExecutableFile(atPath: cand) { return cand }
            dir = dir.deletingLastPathComponent()
        }
        return "/usr/local/bin/m1ddc"
    }

    /// 本机所在的输入源（USB-C 走 DP Alt Mode，固件登记为 15）
    static let myValue = 15
    /// 对端（Windows，接 DisplayPort）的输入源
    static let peerValue = 16

    /// 内置端口配置：本显示器实测值。capability string 不可用时使用。
    static let fallbackSources: [(value: Int, name: String)] = [
        (15, "USB-C"),
        (16, "DisplayPort"),
        (17, "HDMI 1"),
        (18, "HDMI 2"),
    ]

    /// VESA MCCS 2.2 标准 VCP 0x60 输入源值 → 端口类型。
    /// 只在 capability string 解析出内置表以外的值时使用。
    private static let standardNames: [Int: String] = [
        1: "VGA 1", 2: "VGA 2", 3: "DVI 1", 4: "DVI 2",
        5: "复合视频 1", 6: "复合视频 2", 7: "S-Video 1", 8: "S-Video 2",
        9: "电视调谐 1", 10: "电视调谐 2", 11: "电视调谐 3",
        12: "分量 1", 13: "分量 2", 14: "分量 3",
        15: "DisplayPort 1", 16: "DisplayPort 2",
        17: "HDMI 1", 18: "HDMI 2", 19: "HDMI 3", 20: "HDMI 4",
        25: "Thunderbolt", 27: "USB-C",
    ]

    private static let gate = NSLock()
    private static var _sources = fallbackSources
    private static var _knownValues: Set<Int> = [15, 16, 17, 18, 27]
    private static var _displayName = "显示器"
    private static var _portsDetected = false
    private static var _ddcAvailable = false

    /// 只有显示器完全枚举不到（不支持 DDC/CI）时才显示的提示。
    /// 支持时菜单不显示任何说明行，端口列表本身就是结果。
    static let unsupportedText = "该显示器不支持"

    static var sources: [(value: Int, name: String)] {
        gate.lock(); defer { gate.unlock() }
        return _sources
    }
    static var displayName: String {
        gate.lock(); defer { gate.unlock() }
        return _displayName
    }
    static var portsDetected: Bool {
        gate.lock(); defer { gate.unlock() }
        return _portsDetected
    }
    static var ddcAvailable: Bool {
        gate.lock(); defer { gate.unlock() }
        return _ddcAvailable
    }
    static func run(_ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = args
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return ""
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 启动时检测一次：显示器是否存在、是否支持 DDC/CI、能否枚举输入端口。
    ///
    /// MCCS capability string 形如
    ///   (prot(monitor)type(LCD)vcp(02 10 12 60(0F 10 11 12) ...))
    /// 其中 60(...) 就是显示器声明支持的输入源值。这块 ANT27VU 返回
    /// 0xFF 0xFF（空能力串），此时退回内置端口表；这属于「支持」，
    /// 菜单不显示任何不支持提示。
    static func detect() {
        let list = run(["display", "list"])
        let hasDisplay = list.contains("[1]")

        if hasDisplay {
            if let re = try? NSRegularExpression(pattern: #"\[1\]\s+([^\(\n]+?)\s+\("#),
               let m = re.firstMatch(in: list, range: NSRange(list.startIndex..., in: list)),
               let r = Range(m.range(at: 1), in: list) {
                let name = String(list[r]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { setDisplayName(name) }
            }
        }

        let caps = run(["capabilities"])
        let parsed = parseInputSources(caps)
        // 解析结果必须同时包含本机和对端，否则切换流程会失去可写目标，
        // 这种情况下宁可退回实测配置。
        let usable = parsed.count >= 2
            && parsed.contains { $0.value == myValue }
            && parsed.contains { $0.value == peerValue }

        gate.lock()
        _ddcAvailable = hasDisplay
        if usable {
            _sources = parsed
            _knownValues = Set(parsed.map { $0.value })
            _portsDetected = true
        } else {
            _sources = fallbackSources
            _knownValues = [15, 16, 17, 18, 27]
            _portsDetected = false
        }
        gate.unlock()

        print("[Ddc] display=\(_displayName) ddc=\(_ddcAvailable) "
              + "caps=\(caps.isEmpty ? "empty" : String(caps.prefix(60))) "
              + "ports=\(_portsDetected ? "detected" : "fallback") "
              + "unsupported=\(!_ddcAvailable)")
    }

    private static func setDisplayName(_ name: String) {
        gate.lock(); _displayName = name; gate.unlock()
    }

    /// 从 capability string 里解析 VCP 0x60 允许的输入源值，
    /// 并映射到端口类型名称。本显示器实测映射优先于标准值。
    static func parseInputSources(_ caps: String) -> [(value: Int, name: String)] {
        guard !caps.isEmpty else { return [] }
        guard let re = try? NSRegularExpression(pattern: #"60\(([^)]*)\)"#, options: .caseInsensitive),
              let m = re.firstMatch(in: caps, range: NSRange(caps.startIndex..., in: caps)),
              let r = Range(m.range(at: 1), in: caps) else { return [] }

        var result: [(value: Int, name: String)] = []
        var seen = Set<Int>()
        for token in String(caps[r]).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            guard let v = Int(token, radix: 16), v > 0, v < 256, !seen.contains(v) else { continue }
            seen.insert(v)
            let name = fallbackSources.first(where: { $0.value == v })?.name
                ?? standardNames[v]
                ?? "0x" + String(v, radix: 16, uppercase: true)
            result.append((v, name))
        }
        return result.sorted { $0.value < $1.value }
    }

    /// 读当前输入源。读不到返回 nil（可能显示器睡着、或在非活动端）。
    ///
    /// 实测：显示器切离 USB-C 时，scaler 会让 Mac 侧整个 DDC/CI 从设备掉线，
    /// 此时 `get input` 以及亮度/对比度都返回同一个随机噪声（如 34284 / 119 /
    /// 26815），而不是「读不到」。这些噪声既不是端口值，也不能当作「弹回本机」。
    /// 因此这里同时维护通道健康状态，供切屏流程决定是否复位。
    static func readInput() -> Int? {
        let text = run(["get", "input"])
        guard let v = Int(text) else { return nil }
        gate.lock()
        let ok = _knownValues.contains(v)
        gate.unlock()
        healthGate.lock()
        if ok {
            _badReads = 0
            _channelBroken = false
        } else {
            _badReads += 1
            if _badReads >= 2 { _channelBroken = true }
        }
        healthGate.unlock()
        return ok ? v : nil
    }

    // MARK: - DDC 通道健康 / 复位

    private static let healthGate = NSLock()
    private static var _badReads = 0
    private static var _channelBroken = false
    private static var _lastReset = Date.distantPast

    /// 连续读到非端口值的噪声：显示器 DDC 从设备已掉线。
    static var channelBroken: Bool {
        healthGate.lock(); defer { healthGate.unlock() }
        return _channelBroken
    }

    static var badReads: Int {
        healthGate.lock(); defer { healthGate.unlock() }
        return _badReads
    }

    /// 让显示器睡眠再唤醒一次，scaler 会重新初始化 DDC 从设备。
    /// 实测可把持续噪声的通道在 2 秒内恢复成稳定读数；20 秒内不重复执行。
    /// 会短暂黑屏，必须在后台线程调用，且只在空闲/切屏失败收尾时使用。
    static func resetChannel(force: Bool = false) {
        healthGate.lock()
        if !force && Date().timeIntervalSince(_lastReset) < 20 {
            healthGate.unlock()
            return
        }
        _lastReset = Date()
        healthGate.unlock()

        let sleep = Process()
        sleep.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        sleep.arguments = ["displaysleepnow"]
        sleep.standardOutput = Pipe()
        sleep.standardError = Pipe()
        try? sleep.run()
        sleep.waitUntilExit()

        Thread.sleep(forTimeInterval: 1.0)
        let wake = Process()
        wake.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        wake.arguments = ["-u", "-t", "3"]
        wake.standardOutput = Pipe()
        wake.standardError = Pipe()
        try? wake.run()

        healthGate.lock()
        _badReads = 0
        _channelBroken = false
        healthGate.unlock()
    }

    /// 最近若干次 DDC 写操作。只用于诊断「切屏时两端是否互相重复写 0x60」，
    /// 重复写会让显示器在两个输入源之间来回跳并弹「无信号」。
    private static let writeGate = NSLock()
    private static var _writes: [String] = []
    private static let writeStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static var writeLog: String {
        writeGate.lock(); defer { writeGate.unlock() }
        return _writes.joined(separator: ",")
    }

    static func setInput(_ value: Int) {
        writeGate.lock()
        _writes.append("\(writeStamp.string(from: Date())):\(value)")
        if _writes.count > 24 { _writes.removeFirst() }
        writeGate.unlock()
        _ = run(["set", "input", String(value)])
    }

    /// 强制唤醒显示管道。DDC 读不到值多半是显示输出被挂起，
    /// 唤醒后通常能恢复。
    static func wakeDisplay() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        task.arguments = ["-u", "-t", "2"]
        try? task.run()
    }

    /// 读当前输入源；读不到先唤醒再试一次。
    /// 返回 nil 表示确实无法判断（此时不能假设屏幕在哪一端）。
    static func probeInput() -> Int? {
        if let value = readInput() { return value }
        wakeDisplay()
        Thread.sleep(forTimeInterval: 1.2)
        return readInput()
    }

    static func name(of value: Int) -> String {
        sources.first(where: { $0.value == value })?.name
            ?? "0x" + String(value, radix: 16, uppercase: true)
    }
}
