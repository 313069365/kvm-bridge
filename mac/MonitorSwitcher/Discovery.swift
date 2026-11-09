import Foundation
import Darwin

/// 局域网自动发现：在 UDP 24802 上广播本机角色，让 Windows 端不用手填 IP
/// 就能找到作为 TCP 服务端的 Mac。同时监听对端广播，记录 Windows 地址供诊断。
///
/// 报文：`KVMBRIDGE1 <mac|win> <sessionId>`
/// sessionId 用于忽略本机自己发出的广播；跨网段收不到广播时仍可手动指定地址。
final class Discovery {
    static let shared = Discovery()

    private static let port: UInt16 = 24802
    private static let magic = "KVMBRIDGE1"

    private let session: String
    private let queue = DispatchQueue(label: "kvm.discovery", qos: .utility, attributes: .concurrent)
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var running = false
    private var _peerIP = ""

    init() {
        session = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// 最近一次看到对端 Windows 的地址（仅诊断用）
    var peerIP: String {
        lock.lock(); defer { lock.unlock() }
        return _peerIP
    }

    func start() {
        guard !running else { return }
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            print("[Discovery] socket failed: \(errno)")
            return
        }
        fd = sock

        var on: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = in_port_t(Discovery.port).bigEndian
        bindAddr.sin_addr.s_addr = INADDR_ANY
        let ok = withUnsafeMutablePointer(to: &bindAddr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if ok != 0 { print("[Discovery] bind failed: \(errno)") }

        running = true
        queue.async { self.beaconLoop() }
        queue.async { self.listenLoop() }
        print("[Discovery] started, session=\(session) port=\(Discovery.port)")
    }

    private func beaconLoop() {
        let msg = "\(Discovery.magic) mac \(session)"
        while running {
            sendBroadcast(msg)
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    /// macOS 对 255.255.255.255 有限广播会返回 EHOSTUNREACH，
    /// 必须按每个网卡的实际掩码算出定向广播地址再发。
    private func sendBroadcast(_ msg: String) {
        for bc in broadcastAddresses() {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(Discovery.port).bigEndian
            addr.sin_addr.s_addr = bc
            sendMessage(msg, to: &addr)
        }
    }

    /// 收到对端广播后单播回一句：即使广播被网络设备拦掉，只要对端的包
    /// 能到本机，它就能从这条回包的源地址得知 Mac 在哪。
    private func reply(to peer: sockaddr_in, msg: String) {
        var addr = peer
        sendMessage(msg, to: &addr)
    }

    private func sendMessage(_ msg: String, to addr: inout sockaddr_in) {
        msg.withCString { cstr in
            withUnsafeMutablePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(fd, cstr, strlen(cstr), 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func broadcastAddresses() -> [in_addr_t] {
        var list: [in_addr_t] = []
        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifap) == 0, let head = ifap else { return list }
        defer { freeifaddrs(head) }
        var cur: UnsafeMutablePointer<ifaddrs>? = head
        while let p = cur {
            let entry = p.pointee
            if let a = entry.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET),
               let m = entry.ifa_netmask {
                let ip = UnsafeRawPointer(a).assumingMemoryBound(to: sockaddr_in.self).pointee
                let mask = UnsafeRawPointer(m).assumingMemoryBound(to: sockaddr_in.self).pointee
                let bc = ip.sin_addr.s_addr | ~mask.sin_addr.s_addr
                if !list.contains(bc) { list.append(bc) }
            }
            cur = entry.ifa_next
        }
        return list
    }

    private func listenLoop() {
        var buf = [CChar](repeating: 0, count: 512)
        while running {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p -> Int in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buf, buf.count, 0, sa, &len)
                }
            }
            if n <= 0 {
                if !running { break }
                usleep(200_000)
                continue
            }
            let bytes = buf.prefix(n).map { UInt8(bitPattern: $0) }
            let parts = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ")
            guard parts.count >= 3,
                  String(parts[0]) == Discovery.magic,
                  String(parts[1]) == "win",
                  String(parts[2]) != session else { continue }

            var a = from.sin_addr
            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &a, &host, socklen_t(INET_ADDRSTRLEN)) != nil {
                let ip = String(cString: host)
                lock.lock(); _peerIP = ip; lock.unlock()
                reply(to: from, msg: "\(Discovery.magic) mac \(session)")
            }
        }
    }
}
