import Foundation
import Darwin

/// TCP 服务端：等待 Windows 端连接，双向收发报文。
///
/// 三条可靠性设计：
/// 1. 发送走独立串行队列，事件泵线程永不阻塞（阻塞会让系统判定 tap 超时）。
/// 2. 心跳：每 2 秒发 PING，7 秒没收到任何报文就主动断开。
///    没有心跳时 TCP 半开会表现为「已连接但事件石沉大海」，键鼠被吞却不动作。
/// 3. 连接带代数（generation），避免 fd 复用竞态：旧读线程退出时不会误关新连接。
final class RelayServer {

    static let shared = RelayServer()

    private static let heartbeatInterval: TimeInterval = 2.0
    private static let staleLimit: TimeInterval = 7.0
    /// 移动报文积压上限。对端卡住时丢帧而不是把内存撑爆。
    private static let maxPendingMoves = 80

    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var clientGen = 0

    private let lock = NSLock()
    private let stateLock = NSLock()

    private let writeQueue = DispatchQueue(label: "kvm.relay.write")
    private var pendingMoves = 0
    private var lastRecv = Date.distantPast

    private var heartbeat: DispatchSourceTimer?
    private let heartbeatQueue = DispatchQueue(label: "kvm.relay.heartbeat")

    private(set) var isListening = false
    /// 对端是否具备注入能力（辅助功能已授权）。未知时按可用处理。
    var peerCanInject = true

    var onClientChange: ((Bool) -> Void)?
    var onLine: ((String) -> Void)?

    /// 最近一次断开的具体原因。菜单不能只写「等待连接」，
    /// 网络不可达 / 心跳超时 / 对端退出，用户要做的处置完全不同。
    private var _disconnectReason = "等待 Windows 连接（检查对端程序与防火墙 24801）"
    var disconnectReason: String {
        stateLock.lock(); defer { stateLock.unlock() }
        return _disconnectReason
    }
    private func setDisconnectReason(_ text: String) {
        stateLock.lock(); _disconnectReason = text; stateLock.unlock()
    }

    // MARK: - 启停

    func start(port: UInt16 = 24801) -> Bool {
        lock.lock()
        if isListening {
            lock.unlock()
            return true
        }
        lock.unlock()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return false }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0)

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 {
            close(fd)
            return false
        }

        if Darwin.listen(fd, 4) != 0 {
            close(fd)
            return false
        }

        lock.lock()
        listenFD = fd
        isListening = true
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.stackSize = 256 * 1024
        thread.start()

        return true
    }

    func stop() {
        lock.lock()
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        if clientFD >= 0 {
            close(clientFD)
            clientFD = -1
        }
        clientGen += 1
        isListening = false
        lock.unlock()
        stopHeartbeat()
    }

    var hasClient: Bool {
        lock.lock()
        defer { lock.unlock() }
        return clientFD >= 0
    }

    // MARK: - 连接

    private func acceptLoop() {
        while true {
            lock.lock()
            let lfd = listenFD
            lock.unlock()
            if lfd < 0 { return }

            var clientAddr = sockaddr()
            var addrLen = socklen_t(MemoryLayout<sockaddr>.size)
            let cfd = Darwin.accept(lfd, &clientAddr, &addrLen)
            if cfd < 0 { return }

            // 关掉 Nagle：键鼠报文都是小包，攒包会引入几十毫秒延迟
            var nodelay: Int32 = 1
            setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &nodelay,
                       socklen_t(MemoryLayout<Int32>.size))

            lock.lock()
            if clientFD >= 0 {
                // 旧连接直接关闭；它的读线程会因为代数不匹配而不做二次 close
                close(clientFD)
            }
            clientFD = cfd
            clientGen += 1
            let gen = clientGen
            lock.unlock()

            peerCanInject = true
            print("[Relay] accepted gen=\(gen) fd=\(cfd)")
            setDisconnectReason("等待 Windows 连接（检查对端程序与防火墙 24801）")
            startHeartbeat(gen: gen)

            DispatchQueue.main.async { [weak self] in
                self?.onClientChange?(true)
            }

            let reader = Thread { [weak self] in
                self?.readLoop(cfd, gen)
            }
            reader.stackSize = 256 * 1024
            reader.start()
        }
    }

    private func readLoop(_ fd: Int32, _ gen: Int) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = Data()

        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n <= 0 { break }

            stateLock.lock()
            lastRecv = Date()
            stateLock.unlock()

            pending.append(contentsOf: buffer[0..<n])

            // 控制报文都是单行文本，按 \n 切行
            while let idx = pending.firstIndex(of: 0x0A) {
                let chunk = pending[pending.startIndex..<idx]
                pending.removeSubrange(pending.startIndex...idx)
                if let text = String(data: Data(chunk), encoding: .utf8) {
                    let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty {
                        onLine?(line)
                    }
                }
            }
        }

        // 只有自己仍是当前连接时才关闭并通知，避免误关新连接
        lock.lock()
        var owned = false
        if clientGen == gen {
            if clientFD >= 0 { close(clientFD) }
            clientFD = -1
            clientGen += 1
            owned = true
        }
        lock.unlock()

        if owned {
            setDisconnectReason("对端关闭了连接（Windows 端可能已退出或重启）")
            stopHeartbeat()
            DispatchQueue.main.async { [weak self] in
                self?.onClientChange?(false)
            }
        }
    }

    private func dropClient(gen: Int, reason: String = "连接已断开") {
        lock.lock()
        // 只有仍然是这代连接时才关，否则会误杀刚建立的新连接
        if clientGen != gen {
            lock.unlock()
            return
        }
        let had = clientFD >= 0
        if clientFD >= 0 { close(clientFD) }
        clientFD = -1
        clientGen += 1
        lock.unlock()

        stopHeartbeat()
        if had {
            setDisconnectReason(reason)
            DispatchQueue.main.async { [weak self] in
                self?.onClientChange?(false)
            }
        }
    }

    // MARK: - 心跳

    private func startHeartbeat(gen: Int) {
        stopHeartbeat()
        stateLock.lock()
        lastRecv = Date()
        stateLock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(deadline: .now() + Self.heartbeatInterval,
                       repeating: .milliseconds(Int(Self.heartbeatInterval * 1000)))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            self.lock.lock()
            let current = self.clientGen
            let alive = self.clientFD >= 0
            self.lock.unlock()
            guard alive, current == gen else { return }

            self.sendLine("PING")

            self.stateLock.lock()
            let idle = Date().timeIntervalSince(self.lastRecv)
            self.stateLock.unlock()

            if idle > Self.staleLimit {
                print("[Relay] heartbeat timeout gen=\(gen) idle=\(Int(idle))s")
                self.dropClient(gen: gen, reason: "心跳超时：7 秒未收到响应（检查网络 / 路由 / 防火墙）")
            }
        }
        timer.resume()
        heartbeat = timer
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    // MARK: - 发送

    /// 非阻塞发送：入队即返回，事件泵线程不会被 TCP 写阻塞。
    func sendLine(_ line: String) {
        if line.hasPrefix("M ") {
            stateLock.lock()
            if pendingMoves >= Self.maxPendingMoves {
                stateLock.unlock()
                return
            }
            pendingMoves += 1
            stateLock.unlock()
        }

        writeQueue.async { [weak self] in
            guard let self = self else { return }
            self.writeNow(line)
            if line.hasPrefix("M ") {
                self.stateLock.lock()
                if self.pendingMoves > 0 { self.pendingMoves -= 1 }
                self.stateLock.unlock()
            }
        }
    }

    private func writeNow(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }

        lock.lock()
        let fd = clientFD
        lock.unlock()
        if fd < 0 { return }

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
