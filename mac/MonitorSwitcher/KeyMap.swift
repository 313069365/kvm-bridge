import Foundation

/// macOS 虚拟键码（HID usage）→ Windows 虚拟键码（VK）映射。
/// 只在两端之一维护，另一份通过协议下发，避免版本漂移。
enum KeyMap {

    static let macToVK: [Int64: UInt16] = [
        // 字母
        0: 0x41,   // A
        11: 0x42,  // B
        8: 0x43,   // C
        2: 0x44,   // D
        14: 0x45,  // E
        3: 0x46,   // F
        5: 0x47,   // G
        4: 0x48,   // H
        34: 0x49,  // I
        38: 0x4A,  // J
        40: 0x4B,  // K
        37: 0x4C,  // L
        46: 0x4D,  // M
        45: 0x4E,  // N
        31: 0x4F,  // O
        35: 0x50,  // P
        12: 0x51,  // Q
        15: 0x52,  // R
        1: 0x53,   // S
        17: 0x54,  // T
        32: 0x55,  // U
        9: 0x56,   // V
        13: 0x57,  // W
        7: 0x58,   // X
        16: 0x59,  // Y
        6: 0x5A,   // Z

        // 数字
        18: 0x31,  // 1
        19: 0x32,  // 2
        20: 0x33,  // 3
        21: 0x34,  // 4
        23: 0x35,  // 5
        22: 0x36,  // 6
        26: 0x37,  // 7
        28: 0x38,  // 8
        25: 0x39,  // 9
        29: 0x30,  // 0

        // 符号
        24: 0xBB,  // =
        27: 0xBD,  // -
        30: 0xDD,  // ]
        33: 0xDB,  // [
        39: 0xDE,  // '
        41: 0xBA,  // ;
        42: 0xDC,  // backslash
        43: 0xBC,  // ,
        44: 0xBF,  // /
        47: 0xBE,  // .
        50: 0xC0,  // `

        // 编辑键
        36: 0x0D,  // Return
        48: 0x09,  // Tab
        49: 0x20,  // Space
        51: 0x08,  // Delete (backspace)
        53: 0x1B,  // Escape
        117: 0x2E, // Forward Delete
        115: 0x24, // Home
        119: 0x23, // End
        116: 0x21, // Page Up
        121: 0x22, // Page Down

        // 方向键
        123: 0x25, // Left
        124: 0x27, // Right
        125: 0x28, // Down
        126: 0x26, // Up

        // 修饰键
        56: 0xA0,  // Left Shift
        60: 0xA1,  // Right Shift
        59: 0xA2,  // Left Control
        62: 0xA3,  // Right Control
        58: 0xA4,  // Left Option -> Left Alt
        61: 0xA5,  // Right Option -> Right Alt
        55: 0x5B,  // Command -> Left Win
        54: 0x5C,  // Right Command -> Right Win
        57: 0x14,  // Caps Lock

        // 功能键
        122: 0x70, // F1
        120: 0x71, // F2
        99: 0x72,  // F3
        118: 0x73, // F4
        96: 0x74,  // F5
        97: 0x75,  // F6
        98: 0x76,  // F7
        100: 0x77, // F8
        101: 0x78, // F9
        109: 0x79, // F10
        103: 0x7A, // F11
        111: 0x7B  // F12
    ]

    static func vk(for macKeyCode: Int64) -> UInt16? {
        return macToVK[macKeyCode]
    }

    /// 反向映射，Windows 作主控时使用
    static let vkToMac: [UInt16: Int64] = {
        var reversed: [UInt16: Int64] = [:]
        for (mac, vk) in macToVK {
            reversed[vk] = mac
        }
        // Windows 的低级钩子在部分场景上报通用修饰键 VK（左/右不区分），
        // 这里补上映射，否则这些键会被直接丢弃。
        reversed[0x10] = 56   // VK_SHIFT    -> Left Shift
        reversed[0x11] = 59   // VK_CONTROL  -> Left Control
        reversed[0x12] = 58   // VK_MENU     -> Left Option
        reversed[0x5D] = 55   // VK_APPS     -> Left Command
        return reversed
    }()

    static func macKeyCode(forVK vk: UInt16) -> Int64? {
        return vkToMac[vk]
    }
}
