// HevSocksProxy.swift
//
// Swift wrapper around the embedded hev-socks5-server
// (iOS/Vendor/HevSocks5Server.xcframework). 这是本项目唯一的 SOCKS5 引擎。
//
// 四条改动前必读的约束（都踩过坑）：
//
// 1) `hev_socks5_server_main_from_str()` 是**两参数**（str + len），少传长度
//    在 C 里不会报错，只会偶发解析失败——极难定位。
// 2) 该调用**阻塞**，直到 quit 生效或出错。必须跑在专用队列上，绝不能在主线程
//    调用。
// 3) `hev_socks5_server_quit()` 只置停止位，**不等待**。必须等
//    main_from_str 真正返回后才能再次 start，否则新实例撞上未释放的
//    9001 端口。这是本文件里 DispatchGroup 存在的唯一理由——**所以要真等**：
//    等不到就返回 false 让调用方放弃本轮，绝不硬起（见 stop/ensureListening）。
// 4) **健康探针必须做真 SOCKS5 握手**，不能只 connect。内核 listen socket 只要还在，
//    连接就会被 backlog 收下、connect 立刻成功 ⇒ 用户态 accept 已经死了它照样判
//    「健康」。2026-09-20 真机就停在那个状态：Mac 侧经 usbmuxd 连 9001 秒成、随后
//    一个字节都不回，而这里因为 connect 成功而 resetFailures()，看门狗永远走不到
//    stop+start ⇒ 永不自愈（只能杀 App）。见 isServing。

import Foundation
// Xcode 对已链接且带 modulemap 的 framework 会自动隐式 import；这里显式写出，
// 既是依赖声明，也避免未来工具链收紧隐式导入导致「use of unresolved identifier」。
import HevSocks5Server

final class HevSocksProxy {

    private let port: UInt16
    private let bindInterface: String
    private let logLevel: String

    /// 引擎循环专用的队列。qos 用 userInitiated：转发延迟直接影响 Mac 侧
    /// 上网体感，不能放到 utility/background 上被降频。
    private let queue = DispatchQueue(label: "com.example.hev-socks", qos: .userInitiated)

    /// 用来等 main_from_str 返回。见文件头第 3 点。
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var running = false

    /// 看门狗自愈专用的后台串行队列。探针（非阻塞 connect ＋ poll，总预算
    /// `probeTimeoutMS`）与 stop 的 `group.wait(timeout: 5s)` 都跑在这里，绝不碰
    /// 主线程——否则一次慢探针或引擎停不下来就会冻结 UI。串行队列同时保证
    /// 「上一轮自愈未完成时，下一轮 8s 看门狗不会叠加上来」。
    private let watchdogQueue = DispatchQueue(label: "com.example.hev-watchdog", qos: .utility)

    /// 连续探针失败次数。真握手下一次失败就意味着「引擎这一个周期没回话」，
    /// 但 hev 在高负载（workers:2 / limit-nofile:512）下偶尔慢一拍是正常的，
    /// 单次超时误判就会 stop+start、掐断 Mac 侧所有正在转发的会话。只有连续
    /// 多次失败才真正自愈。
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3

    /// 单次探针的总预算（毫秒）：connect 阶段与握手应答阶段各自最多用这么多。
    private static let probeTimeoutMS: Int32 = 800

    /// 真实**服务**探针：连上端口 **并且** 跑完一次 SOCKS5 无鉴权握手
    /// （发 `05 01 00`、收到 `05 00`）。
    ///
    /// 为什么不只 connect：内核 listen socket 只要还在，连接就会被 backlog 收下、
    /// `connect()` 立刻成功——**用户态 accept 循环已经死了它也判「健康」**。这正是
    /// 2026-09-20 那次隧道一直不通的直接原因（详见文件头第 4 点）。判据必须验到
    /// 「引擎真的回话了」为止。
    ///
    /// 超时自己兜：Darwin 上 `SO_SNDTIMEO` **不约束 `connect()`**（旧注释宣称的
    /// 0.3s 超时其实不存在），所以 connect 走非阻塞 ＋ `poll()`；应答阶段用
    /// `SO_RCVTIMEO`（这个才真管 `recv`）。探针全程只读写回环、不参与转发，
    /// 对 hev 无副作用。
    var isServing: Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock != -1 else { return false }
        defer { close(sock) }

        guard connectLoopback(sock, timeoutMS: Self.probeTimeoutMS) else { return false }
        return socks5Handshake(sock, timeoutMS: Self.probeTimeoutMS)
    }

    /// 非阻塞 connect 到 `127.0.0.1:port`，带真正的超时（`poll` 兜底）。
    /// 成功（含 `EINPROGRESS` 后转为可写且 `SO_ERROR == 0`）返回 true。
    private func connectLoopback(_ sock: Int32, timeoutMS: Int32) -> Bool {
        let originalFlags = fcntl(sock, F_GETFL, 0)
        guard originalFlags != -1 else { return false }
        _ = fcntl(sock, F_SETFL, originalFlags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            // 回环 connect 只会立刻成功或 `EINPROGRESS`，其余都是真失败。
            guard errno == EINPROGRESS else { return false }
            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, timeoutMS) > 0 else { return false }
            var soError: Int32 = 0
            var soLen = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &soLen) == 0,
                  soError == 0 else { return false }
        }
        // 恢复原阻塞态：应答阶段要靠 SO_RCVTIMEO 限时，非阻塞 socket 上 recv 会直接 EAGAIN。
        _ = fcntl(sock, F_SETFL, originalFlags)
        return true
    }

    /// 发一次 SOCKS5 无鉴权问候并等 `05 00`。引擎**真在干活**才算通过。
    private func socks5Handshake(_ sock: Int32, timeoutMS: Int32) -> Bool {
        var tv = timeval(tv_sec: Int(timeoutMS / 1000),
                         tv_usec: Int32((timeoutMS % 1000) * 1000))
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv,
                       socklen_t(MemoryLayout<timeval>.size))

        let greeting: [UInt8] = [0x05, 0x01, 0x00]
        let sent = greeting.withUnsafeBytes { send(sock, $0.baseAddress, $0.count, 0) }
        guard sent == greeting.count else { return false }

        var reply = [UInt8](repeating: 0, count: 2)
        let got = reply.withUnsafeMutableBytes { recv(sock, $0.baseAddress, 2, 0) }
        guard got == 2 else { return false }
        return reply[0] == 0x05 && reply[1] == 0x00
    }

    /// - parameter bindInterface: 强制出站走这个网络接口。iPad 的 Wi-Fi 通常是
    ///   `en0`（本仓真机已验证）。填错的后果是 `set_sock_bind()` 返回 -1，
    ///   每个连接都在握手阶段直接失败——症状是「能连上代理但打不开任何页面」。
    ///   排查时把它改成 ""（不绑接口）即可区分。
    init(port: UInt16 = 9001, bindInterface: String = "en0", logLevel: String = "warn") {
        self.port = port
        self.bindInterface = bindInterface
        self.logLevel = logLevel
    }

    @discardableResult
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return true }

        let yaml = Self.configYAML(port: port, bindInterface: bindInterface,
                                   logLevel: logLevel)
        running = true
        group.enter()

        queue.async {
            defer {
                // ★ 顺序要紧：先把 running 置 false，再 leave()。
                // 反过来（旧写法）会留一个窄竞态：group.wait 在 running 还是 true 时
                // 就返回，紧接着的 start() 撞上 `guard !running` 直接返回、什么都不做
                // ⇒ 引擎再也起不来。
                self.lock.lock()
                self.running = false
                self.lock.unlock()
                self.group.leave()
            }
            let len = UInt32(yaml.utf8.count)
            let rc = yaml.withCString { cstr -> Int32 in
                let bytes = UnsafeRawPointer(cstr).assumingMemoryBound(to: UInt8.self)
                return hev_socks5_server_main_from_str(bytes, len)
            }
            // 非 0 必打 ⚠️：这条退出路径是「引擎真的死了」的唯一证据，淹没在
            // 一堆 rc=0 里就等于没有日志。
            if rc == 0 {
                NSLog("[HevSocks] main_from_str 返回 rc=0（正常退出）")
            } else {
                NSLog("[HevSocks] ⚠️ main_from_str 返回 rc=%d（非 0 = 配置、绑定或运行出错）", rc)
            }
        }

        NSLog("[HevSocks] 已启动 127.0.0.1:%d（bind-interface=%@, log=%@）",
              Int(port), bindInterface.isEmpty ? "<不绑接口>" : bindInterface, logLevel)
        return true
    }

    /// 停止引擎。返回 **是否真的停干净了**（`main_from_str` 已在 5s 内返回）。
    ///
    /// 调用方**必须**看返回值：`quit()` 只置停止位，引擎不退时 9001 仍被占着，
    /// 此时再 `start()` 会 bind 失败（rc≠0）并留下一枚「socket 在、不干活」的死占
    /// —— 那正是旧探针看不出来的状态，会永久失去自愈能力。停不掉就本轮放弃，
    /// 下一轮看门狗再来（`quit()` 可重复调用，重试是廉价的）。
    @discardableResult
    func stop() -> Bool {
        lock.lock()
        let wasRunning = running
        lock.unlock()
        guard wasRunning else { return true }

        hev_socks5_server_quit()

        // 必须等 main_from_str 真正返回。5s 是经验值：hev 的停止路径是协作式的，
        // 正常情况下 一轮调度内就会退出。
        if group.wait(timeout: .now() + 5) == .timedOut {
            NSLog("[HevSocks] ⚠️ 引擎 5s 内未退出，端口 %d 可能仍被占用", Int(port))
            return false
        }
        return true
    }

    /// 看门狗自愈入口：探针失败连续 N 次才 stop+start。
    func ensureListening() {
        // 整个「探针 + 可能的重启」都派发到后台队列，主线程完全不阻塞。
        // 见 watchdogQueue / maxConsecutiveFailures 两处注释。
        watchdogQueue.async { [weak self] in
            guard let self else { return }
            // 探针 = 真握手（见 isServing：connect 成功不代表引擎在干活）。
            guard !self.isServing else {
                self.resetFailures()
                return
            }
            self.lock.lock()
            self.consecutiveFailures += 1
            let n = self.consecutiveFailures
            self.lock.unlock()
            NSLog("[HevSocks] 引擎探针失败（连续 %d/%d 次）", n, self.maxConsecutiveFailures)
            // 只有连续多次失败才真重启，避免 hev 高负载下一两次慢应答误判。
            guard n >= self.maxConsecutiveFailures else { return }
            self.resetFailures()
            // ★ 停干净才起：旧实例还占着 9001 时硬 start 只会 bind 失败，
            //   留下「端口在、不干活」的死占（见 stop 的说明）。
            guard self.stop() else {
                NSLog("[HevSocks] 旧引擎未停干净，本轮放弃重启，等下一轮探针重试")
                return
            }
            NSLog("[HevSocks] 连续 %d 次探针失败，执行 stop+start 自愈", self.maxConsecutiveFailures)
            _ = self.start()
        }
    }

    private func resetFailures() {
        lock.lock()
        consecutiveFailures = 0
        lock.unlock()
    }

    // MARK: - 配置

    /// 生成 hev-socks5-server 的 YAML 配置。
    ///
    /// 参数取值依据见规格 5.1（A8 双核 / 2GB 内存）。
    /// ⚠️ server 端的 `misc` **没有** `tcp-buffer-size` 和 `max-session-count`
    /// （那两个是 hev-socks5-tunnel 的配置项），写了会被静默忽略。
    static func configYAML(port: UInt16, bindInterface: String, logLevel: String) -> String {
        return """
        main:
          workers: 2
          port: \(port)
          listen-address: '127.0.0.1'
          bind-interface: '\(bindInterface)'
        misc:
          task-stack-size: 24576
          connect-timeout: 10000
          tcp-read-write-timeout: 300000
          log-file: stderr
          log-level: \(logLevel)
          limit-nofile: 512
        """
    }
}
