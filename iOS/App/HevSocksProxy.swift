// HevSocksProxy.swift
//
// Swift wrapper around the embedded hev-socks5-server
// (iOS/Vendor/HevSocks5Server.xcframework).
//
// 与 microsocks 的 SocksProxy 有三处关键差异，改动前先读：
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

final class HevSocksProxy: SocksProxying {

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

    var engineName: String { "hev" }

    /// hev 没有 is_running 探针，这里只能报告「引擎循环还活着」。
    ///
    /// 相比 microsocks 的 socksbridge_is_running() 弱一档：iOS 若回收了监听
    /// socket，这里仍然返回 true。缓解手段是进退台时走 ensureListening()
    /// 做一次完整的 stop + start，而不是相信这个标志。
    var isListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// - parameter bindInterface: 强制出站走这个网络接口，等价于 microsocks
    ///   时代 Network.framework 的 `requiredInterfaceType = .wifi`。
    ///   iPad 的 Wi-Fi 通常是 `en0`，但**必须在真机上确认**。填错的后果是
    ///   `set_sock_bind()` 返回 -1，每个连接都在握手阶段直接失败——症状是
    ///   「能连上代理但打不开任何页面」。排查时把它改成 ""（不绑接口）即可区分。
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
            NSLog("[HevSocks] main_from_str 返回 rc=%d（0=正常退出，-1=配置或运行出错）", rc)
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

    func ensureListening() {
        lock.lock()
        let alive = running
        lock.unlock()

        if alive { return }

        // 这里 running 已经是 false，stop() 会直接返回，不会触发等待。
        // 之所以还调用一次，是为了处理「循环已退出但 group 尚未 leave」的
        // 极窄窗口。
        stop()
        _ = start()
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
