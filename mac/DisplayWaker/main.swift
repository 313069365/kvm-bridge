import Cocoa
import CoreGraphics

/// 显示器重新连接/配置变化时，主动唤醒 macOS 的显示输出。
///
/// 背景：显示器切回 USB-C 后，链路会重建（HPD 重新协商），但 macOS 的显示
/// 管道可能停在未激活状态，导致显示器判定"无信号"并反复重试同步。
/// caffeinate -u 会声明用户活跃，促使系统重新输出画面。
///
/// 本工具不申请辅助功能权限，只用 caffeinate，因此不涉及 TCC 授权。

func wakeDisplay(reason: String) {
    let stamp = DateFormatter()
    stamp.dateFormat = "HH:mm:ss.SSS"

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    p.arguments = ["-u", "-t", "3"]
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        return
    }

    appendLog("[\(stamp.string(from: Date()))] wake (\(reason))")
}

func appendLog(_ line: String) {
    let path = "/tmp/kvm-waker.log"
    let full = line + "\n"
    if let data = full.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            try? full.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

let reconfigCallback: CGDisplayReconfigurationCallBack = { display, flags, userInfo in
    let interesting = flags.contains(.addFlag)
        || flags.contains(.setModeFlag)
        || flags.contains(.desktopShapeChangedFlag)
        || flags.contains(.movedFlag)

    if interesting {
        DispatchQueue.global().async {
            wakeDisplay(reason: "display reconfig flags=\(flags.rawValue)")
        }
    }
}

appendLog("=== waker start \(Date()) ===")

CGDisplayRegisterReconfigurationCallback(reconfigCallback, nil)

DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    wakeDisplay(reason: "startup")
}

RunLoop.main.run()
