import Cocoa
import CoreGraphics

/// 强制显卡重新建立显示时序。
///
/// 切回本机时，显示器链路是通的（DDC 能读），但 macOS 的显示管道未必
/// 重新输出有效画面，显示器就会报「无信号」并反复重试同步。
/// 用一次显示配置事务重新应用当前模式，可以强制重握手。
enum DisplayKick {

    /// 重新应用当前显示模式（会话级，不写入用户偏好）
    static func once() {
        let displayID = CGMainDisplayID()
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config = config else {
            // 拿不到配置对象时退回直接设置
            CGDisplaySetDisplayMode(displayID, mode, nil)
            return
        }

        CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        print("[Kick] reconfigure result=\(result.rawValue)")
    }

    /// 可用开关（调试端口 kickoff / kickon），用于对比是否值得执行
    static var enabled = true

    /// 连续执行若干次，覆盖显示器重新识别的那几秒。
    /// 节奏不能太密：A/B 实测过密（每 0.6s）反而更慢，因为会打断显示器自身的同步。
    static func series(_ delays: [Double] = [0.0, 1.2, 2.8, 4.6]) {
        guard enabled else { return }
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Ddc.wakeDisplay()
                once()
            }
        }
    }
}
