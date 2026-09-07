// HevSocksProxy.swift
//
// Swift wrapper around the embedded hev-socks5-server
// (iOS/Vendor/HevSocks5Server.xcframework). 这是本项目唯一的 SOCKS5 引擎。
//
// 三条改动前必读的约束（都踩过坑）：
//
// 1) `hev_socks5_server_main_from_str()` 是**两参数**（str + len），少传长度
//    在 C 里不会报错，只会偶发解析失败——极难定位。
// 2) 该调用**阻塞**，直到 quit 生效或出错。必须跑在专用队列上，绝不能在主线程
//    调用。
// 3) `hev_socks5_server_quit()` 只置停止位，**不等待**。必须等
//    main_from_str 真正返回后才能再次 start，否则新实例撞上未释放的
//    9001 端口。这是本文件里 DispatchGroup 存在的唯一理由。

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

    /// 看门狗自愈专用的后台串行队列。探针（阻塞 connect）与 stop 的
    /// `group.wait(timeout: 5s)` 都跑在这里，绝不碰主线程——否则一次慢探针或
    /// 引擎停不下来就会冻结 UI（最坏 ~5.3s）。串行队列同时保证「上一轮自愈
    /// 未完成时，下一轮 8s 看门狗不会叠加上来」。
    private let watchdogQueue = DispatchQueue(label: "com.example.hev-watchdog", qos: .utility)

    /// 连续探针失败次数。hev 高负载（workers:2 / limit-nofile:512）时，一次
    /// 回环 connect 也可能超过 0.3s，单凭一次超时误判就会 stop+start、掐断
    /// Mac 侧所有正在转发的会话。只有连续多次失败才真正自愈。
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3

    /// 真实端口探针：现在能否连上 `127.0.0.1:port`。
    ///
    /// 早期实现只返回 `running`（引擎循环还活着），无法发现 iOS 回收了监听
    /// socket 的情况——表现为「App 以为在监听，Mac 侧却 ConnectionRefused」，
    /// 曾导致 9001 被死占、必须杀 App 才能恢复。这里用一次带短超时的 TCP
    /// connect 兜底，让看门狗能真正自愈。
    ///
    /// 探测成功即关闭连接，不参与 SOCKS 握手，对 hev 无副作用；端口正常时
    /// 回环连接瞬时成功，不会卡顿。仅当端口真死时 connect 才阻塞到超时
    /// （0.3s），而那种状态下本就该尽快自愈。
    var isListening: Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock != -1 else { return false }
        defer { close(sock) }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)   // 0.3s 探测超时
        _ = setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return res == 0
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
                self.group.leave()
                self.lock.lock()
                self.running = false
                self.lock.unlock()
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
                NSLog("[HevSocks] ⚠️ main_from_str 返回 rc=%d（非 0 = 配置或运行出错）", rc)
            }
        }

        NSLog("[HevSocks] 已启动 127.0.0.1:%d（bind-interface=%@, log=%@）",
              Int(port), bindInterface.isEmpty ? "<不绑接口>" : bindInterface, logLevel)
        return true
    }

    func stop() {
        lock.lock()
        let wasRunning = running
        lock.unlock()
        guard wasRunning else { return }

        hev_socks5_server_quit()

        // 必须等 main_from_str 真正返回。超时只记日志——调用方可能是主线程，
        // 不能无限等。5s 是经验值：hev 的停止路径是协作式的，正常情况下
        // 一轮调度内就会退出。
        if group.wait(timeout: .now() + 5) == .timedOut {
            NSLog("[HevSocks] ⚠️ 引擎 5s 内未退出，端口 %d 可能仍被占用", Int(port))
        }
    }

    /// 看门狗自愈入口：探针失败连续 N 次才 stop+start。
    func ensureListening() {
        // 整个「探针 + 可能的重启」都派发到后台队列，主线程完全不阻塞。
        // 见 watchdogQueue / maxConsecutiveFailures 两处注释。
        watchdogQueue.async { [weak self] in
            guard let self else { return }
            // 端口探针（isListening 内部是一次带 0.3s 超时的阻塞 connect）。
            guard !self.isListening else {
                self.resetFailures()
                return
            }
            self.lock.lock()
            self.consecutiveFailures += 1
            let n = self.consecutiveFailures
            self.lock.unlock()
            NSLog("[HevSocks] 端口探针失败（连续 %d/%d 次）", n, self.maxConsecutiveFailures)
            // 只有连续多次失败才真重启，避免 hev 高负载下一两次慢 connect 误判。
            guard n >= self.maxConsecutiveFailures else { return }
            self.resetFailures()
            // stop 的 group.wait(timeout:5s) 在后台队列上，不卡 UI。
            NSLog("[HevSocks] 连续 %d 次探针失败，执行 stop+start 自愈", self.maxConsecutiveFailures)
            self.stop()
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
