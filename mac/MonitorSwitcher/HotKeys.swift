import Cocoa
import Carbon.HIToolbox

/// 全局热键（Carbon RegisterEventHotKey）。
///
/// 用它而不是 CGEventTap，是因为热键不该依赖辅助功能授权：
/// 权限被系统撤销时，热键仍然要能把屏幕切回来。
/// 语义是绝对的：⌃⌥1 = 切到 Mac，⌃⌥2 = 切到 Windows，两端完全一致。
final class HotKeys {

    static let shared = HotKeys()

    /// 参数是目标输入源的 VCP 值
    var onTrigger: ((Int) -> Void)?

    /// 注册结果的文字描述，直接显示在菜单里，避免"静默失败"
    private(set) var statusText = "未注册"

    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    func register() {
        guard handlerRef == nil else { return }

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, event, _ in
            guard let event = event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            if status == noErr {
                print("[HotKeys] fired id=\(hotKeyID.id)")
                HotKeys.shared.onTrigger?(Int(hotKeyID.id))
            } else {
                print("[HotKeys] param error \(status)")
            }
            return noErr
        }

        let install = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &type, nil, &handlerRef)
        if install != noErr {
            statusText = "安装事件处理器失败 (\(install))"
            print("[HotKeys] InstallEventHandler failed: \(install)")
            return
        }

        let a = registerKey(id: UInt32(Ddc.myValue), key: UInt32(kVK_ANSI_1))
        let b = registerKey(id: UInt32(Ddc.peerValue), key: UInt32(kVK_ANSI_2))

        if a == noErr && b == noErr {
            statusText = "已注册 ⌃⌥1 / ⌃⌥2"
            print("[HotKeys] registered OK (a=\(a) b=\(b))")
        } else {
            statusText = "注册失败 a=\(a) b=\(b)"
            print("[HotKeys] register failed a=\(a) b=\(b)")
        }
    }

    private func registerKey(id: UInt32, key: UInt32) -> OSStatus {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B56_4D42), id: id)   // 'KVMB'
        let status = RegisterEventHotKey(key,
                                         UInt32(controlKey | optionKey),
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        if status == noErr, let ref = ref {
            refs.append(ref)
        }
        return status
    }

    deinit {
        for ref in refs { UnregisterEventHotKey(ref) }
        if let handlerRef = handlerRef { RemoveEventHandler(handlerRef) }
    }
}
