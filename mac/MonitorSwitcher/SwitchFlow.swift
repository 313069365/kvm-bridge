import AppKit

enum ScreenOwner {
    case me            // 屏幕在本机
    case peer          // 屏幕在对端
    case third(Int)    // 屏幕在 HDMI 等第三方设备上
    case unknown       // 状态不确定（切换失败且没检测回原状）
}

/// 切屏流程：发起 → 对端确认 → 提交；失败则尝试回滚。
///
/// 两端跑同一套逻辑，只有 myValue / peerValue 互换。
/// 关键约束（实测得出）：只有当前持有屏幕的那一端能写 DDC 生效，
/// 所以"切走"总是由持有者执行，"切回"由对端用 ASK 请求持有者执行。
///
/// 重要：写 DDC 走的是视频线 I2C，是本地硬件操作，与 IP 网络无关。
/// 网络只用于两件事：① 切换后让对端确认能出画；② 没画面那台请求对方代切。
/// 因此"本机持有屏幕时切走"绝不能因为对端离线而被拒绝。
///
/// 协议（行文本，\n 结尾）：
///   ASK v   请对端把屏幕切到 v（对端是当前持有者）
///   GO  v   我已经写了 DDC v，请你验证能否读到自己
///   OK  v   我读到了自己，切换成功
///   NO  v   我读不到，切换失败
final class SwitchFlow {

    static let shared = SwitchFlow()

    private let myValue = Ddc.myValue
    private let peerValue = Ddc.peerValue

    private(set) var busy = false
    private(set) var status = "就绪"

    /// 状态变化（主线程）
    var onUpdate: (() -> Void)?
    /// 屏幕归属变化（主线程），用于决定是否开启键鼠转发
    var onOwnerChange: ((ScreenOwner) -> Void)?

    private let queue = DispatchQueue(label: "kvm.switch.flow")
    private var epoch = 0

    private func valid(_ value: Int) -> Bool {
        return Ddc.sources.contains { $0.value == value }
    }

    // MARK: - 入口

    /// 菜单点击或热键触发都走这里。value 是目标输入源。
    /// 切屏不要求对端在线；对端离线时仍能本地写 DDC，只是无法确认信号。
    func requestSwitch(to target: Int) {
        guard valid(target) else {
            Toast.shared.show("无效的输入源：\(target)")
            return
        }
        print("[Flow] request target=\(target) busy=\(busy)")
        DispatchQueue.main.async {
            if self.busy {
                self.status = "正在切换中…"
                self.onUpdate?()
                return
            }
            self.busy = true
            self.status = "正在切到 \(Ddc.name(of: target))…"
            self.onUpdate?()
            self.queue.async { self.perform(target) }
        }
    }

    // MARK: - 本机发起

    private func perform(_ target: Int) {
        let current = Ddc.probeInput()
        let active = (current == myValue)
        print("[Flow] perform target=\(target) current=\(String(describing: current)) connected=\(RelayServer.shared.hasClient)")

        // ① 切到自己
        if target == myValue {
            if active {
                complete(success: true, owner: .me, note: "屏幕已在本机")
                return
            }
            guard RelayServer.shared.hasClient else {
                // 本机不是活动输入口，写 DDC 不生效；只能请对端代写，或按显示器按键。
                // 这是显示器的物理限制，与「是否同网段」无关，只与「能否通信」有关。
                complete(success: false, owner: .me,
                         note: "本机没有画面：显示器只响应当前输入口，需 Windows 在线代切，或按显示器按键")
                return
            }
            // 屏幕可能停在 HDMI 这类第三方输入上：两端都写不了 DDC，
            // 发 ASK 只会白等 18 秒，直接告诉用户要按显示器按键。
            if let cur = current, cur != peerValue {
                complete(success: false, owner: .third(cur),
                         note: "屏幕在 \(Ddc.name(of: cur))，请用显示器按键切回")
                return
            }
            ui("请求 Windows 切回…")
            armTimeout(seconds: 12)
            RelayServer.shared.sendLine("ASK \(myValue)")
            return
        }

        // ② 切到对端
        if target == peerValue {
            // 只有明确读到"对端持有屏幕"才跳过；读不到时不能假设，仍然走切换
            if current == peerValue {
                complete(success: true, owner: .peer, note: "屏幕已在 Windows")
                return
            }
            if RelayServer.shared.hasClient {
                Ddc.setInput(peerValue)
                ui("已发出切换，等待 Windows 确认…")
                armTimeout(seconds: 12)
                RelayServer.shared.sendLine("GO \(peerValue)")
            } else {
                // 本机正持有屏幕 → 本地 DDC 完全够用，不因对端离线而拒绝。
                // 降级点只是「没人能确认目标端出画」，以及「之后切回要靠对方」。
                blindSwitch(to: peerValue)
            }
            return
        }

        // ③ 第三方输入（HDMI 等）：没有对端可验证，只能切了再看
        Ddc.setInput(target)
        Thread.sleep(forTimeInterval: 2.5)
        let now = Ddc.readInput()
        if now == target {
            complete(success: true, owner: .third(target), note: "已切到 \(Ddc.name(of: target))")
        } else if now == nil {
            // 读不到说明链路已不指向本机，通常就是切成功了，但无法确认
            complete(success: true, owner: .third(target),
                     note: "已切到 \(Ddc.name(of: target))（无法确认）")
        } else {
            complete(success: false, owner: .me, note: "切换失败，屏幕仍在 \(Ddc.name(of: now!))")
        }
    }

    /// 对端不在线时的降级切换：切完只能看自己还能不能读回自己的值，
    /// 读得回来说明屏幕弹回了本机（失败），读不回来视为切走了。
    /// 这种情况不交出键鼠——没人能确认目标端真的有信号。
    private func blindSwitch(to target: Int) {
        ui("对端离线，直接写 DDC \(target)（不依赖网络）…")
        Ddc.setInput(target)
        Thread.sleep(forTimeInterval: 3.0)
        if Ddc.probeInput() == myValue {
            complete(success: false, owner: .me, note: "切换失败：屏幕弹回了本机")
        } else {
            // 成功也必须给即时反馈：切走后本机不再是活动输入口，写 DDC 无效，
            // 只能靠 Windows 端操作或显示器物理按键切回来。
            Toast.shared.show("已切到 Windows（未验证信号）；切回请在 Windows 上操作或按显示器按键")
            // 关键：归属只能由「已确认的切换」写入。
            // 离线盲切没有对端确认，真实屏幕可能仍在 Mac；若在这里写 .peer，
            // 重启后会按这个错误归属立刻截获本机键鼠，用户感觉鼠标被吞。
            complete(success: true, owner: .unknown,
                     note: "已切到 Windows（未确认信号，归属未确认、未交出键鼠）")
        }
    }

    /// 只判断「现在发起切换会走哪条路径」，不写 DDC。
    /// 用于在不能真的切屏时验证网络门禁是否已解除。
    func describe(target: Int) -> String {
        guard valid(target) else { return "invalid-target(\(target))" }
        let current = Ddc.probeInput()
        let online = RelayServer.shared.hasClient

        if target == myValue {
            if current == myValue { return "already-me | 屏幕已在本机，无需动作" }
            if !online {
                return "need-peer-offline | 本机非活动输入口，写 DDC 无效；需 Windows 在线代切或按显示器按键"
            }
            if let cur = current, cur != peerValue {
                return "third(\(cur)) | 屏幕在 \(Ddc.name(of: cur))，请用显示器按键切回"
            }
            return "ask-peer | 发 ASK 请 Windows 写 DDC \(myValue)"
        }
        if target == peerValue {
            if current == peerValue { return "already-peer | 屏幕已在 Windows，无需动作" }
            if online {
                return "local-ddc+confirm | 本机写 DDC \(peerValue)，GO/OK 确认（网络只用于确认）"
            }
            return "local-ddc-offline | 本机写 DDC \(peerValue)，无需网络，不确认信号、不交出键鼠"
        }
        return "third-party | 直接写 DDC \(target)"
    }

    private func armTimeout(seconds: Double) {
        epoch += 1
        let token = epoch
        queue.asyncAfter(deadline: .now() + seconds) {
            guard token == self.epoch, self.busy else { return }
            self.status = "等待对端确认超时，检查屏幕状态…"
            DispatchQueue.main.async { self.onUpdate?() }
            let back = self.waitForOwnInput(seconds: 6)
            self.complete(success: false,
                          owner: back ? .me : .unknown,
                          note: back ? "切换失败，屏幕已回到本机" : "切换失败，状态未知，请用显示器按键确认")
        }
    }

    // MARK: - 对端消息

    func handle(_ line: String) {
        let parts = line.split(separator: " ").map(String.init)
        guard let verb = parts.first else { return }
        let value = parts.count > 1 ? (Int(parts[1]) ?? -1) : -1

        // 对端也可能发来非法值，一律不执行
        guard valid(value) else { return }

        switch verb {
        case "ASK": queue.async { self.onAsk(value) }
        case "GO":  queue.async { self.onGo(value) }
        case "OK":  queue.async { self.onOk(value) }
        case "NO":  queue.async { self.onNo(value) }
        default:    break
        }
    }

    /// 对端请求我切出（它认为屏幕在我这里）
    private func onAsk(_ value: Int) {
        guard Ddc.probeInput() == myValue else {
            RelayServer.shared.sendLine("NO \(myValue)")
            return
        }
        if !busy {
            busy = true
            DispatchQueue.main.async { self.onUpdate?() }
            armTimeout(seconds: 12)
        }
        ui("对端请求切出，正在执行…")
        Ddc.setInput(value)
        RelayServer.shared.sendLine("GO \(value)")
    }

    /// 对端已写入我的值，验证我是否真的拿到了画面
    private func onGo(_ value: Int) {
        // CGCompleteDisplayConfiguration 每调用一次都会短暂切断 Mac 的视频输出，
        // 显示器随即弹「无信号」并闪烁。它本是早期修黑屏的手段，但在切回路径上
        // 本身就是闪烁源：DDC 验证偶尔慢一拍就会触发 series 连做两次重配。
        // 现在彻底不做显示模式重配，只声明用户活跃（caffeinate，无害）。
        // 读不到自己时如实回 NO，由发起端回滚，绝不主动打断视频输出。
        Ddc.wakeDisplay()
        let ok = waitForOwnInput(seconds: 9)

        if ok {
            RelayServer.shared.sendLine("OK \(myValue)")
            complete(success: true, owner: .me, note: "屏幕已切到本机")
            return
        }

        // 验证失败也必须收尾，否则 busy 会永久卡住，之后所有切换都被拒绝
        RelayServer.shared.sendLine("NO \(myValue)")
        let now = Ddc.readInput()
        if now == myValue {
            complete(success: true, owner: .me, note: "屏幕已切到本机")
        } else if now == peerValue {
            complete(success: false, owner: .peer, note: "切换失败，屏幕仍在 Windows")
        } else {
            complete(success: false, owner: .unknown, note: "切换失败，状态未知")
        }
    }

    /// 我发起的切出成功了
    private func onOk(_ value: Int) {
        guard busy else { return }
        epoch += 1
        if value == peerValue {
            complete(success: true, owner: .peer, note: "已切到 Windows")
        } else {
            complete(success: true, owner: .me, note: "已切回本机")
        }
    }

    /// 对端没看到信号：尝试确认是否已自动回到本机
    private func onNo(_ value: Int) {
        guard busy else { return }
        epoch += 1
        let back = waitForOwnInput(seconds: 6)
        complete(success: false,
                 owner: back ? .me : .unknown,
                 note: back ? "切换失败，屏幕已回到本机" : "切换失败，状态未知")
    }

    // MARK: - 工具

    private func waitForOwnInput(seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if Ddc.readInput() == myValue { return true }
            // 切回瞬间 USB-C 链路正在重新训练，密集读 DDC 既读不到值，
            // 又会持续占用 I2C 干扰显示器同步。放宽到 0.8s 一次。
            Thread.sleep(forTimeInterval: 0.8)
        }
        return false
    }

    private func ui(_ text: String) {
        DispatchQueue.main.async {
            self.status = text
            self.onUpdate?()
        }
    }

    private func complete(success: Bool, owner: ScreenOwner, note: String) {
        print("[Flow] complete success=\(success) owner=\(owner) note=\(note)")
        // 递增 epoch，让已排队的超时任务失效，避免二次 complete 覆盖状态
        epoch += 1
        DispatchQueue.main.async {
            self.busy = false
            self.status = note
            // 失败必须有即时可感的反馈：菜单栏只显示图标，靠"下次打开菜单"太晚
            if !success {
                NSSound.beep()
                Toast.shared.show(note)
            }
            self.onUpdate?()
            self.onOwnerChange?(owner)
        }
    }
}
