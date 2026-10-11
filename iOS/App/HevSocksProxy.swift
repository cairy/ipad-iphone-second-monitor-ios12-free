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
// 5) **启停一律走 startAsync / stopAsync**（都派发到同一条串行队列）。`stop()` 里那个
//    5s `group.wait` 绝不能在主线程上等（界面会卡死），而「关掉又立刻打开」也必须
//    保持先后顺序，否则 start 撞上没停掉的旧实例会静默空转。

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
    /// 但 hev 在高负载（workers:2 / limit-nofile:2048）下偶尔慢一拍是正常的，
    /// 单次超时误判就会 stop+start、掐断 Mac 侧所有正在转发的会话。只有连续
    /// 多次失败才真正自愈。
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3

    /// 健康结论的变化回调（**主队列**投递）。`true`/`false` = 探针结论；`nil` = 引擎
    /// 已被本对象停掉（用户把设置页那个开关关了），健康与否无从谈起。
    ///
    /// 只在**结论变化**时才回调：8s 一拍都回调，会让下游（写 defaults 供设置页显示）
    /// 每 8s 惊动一次观察者，也让主线程白白挨一圈。
    var onHealthChange: ((Bool?) -> Void)?

    /// 最近一次探针结论（`nil` = 未知）。读方在主线程、写方在 watchdogQueue，
    /// 故用既有的 lock 保护。
    private var lastHealthy: Bool?

    var health: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return lastHealthy
    }

    /// 是否有人叫过引擎退出（`stop()` 置位，`main_from_str` 返回时消费）。
    /// 用来区分「我们停的」与「它自己没的」——旧写法两者都只写 `rc=0` 一条，
    /// 于是自愈时每轮一条正常退出记录，会把「引擎无故自己退出」这条真线索淹掉。
    private var quitRequested = false

    /// 故障原因。**只用于日志去重，不参与任何控制流**（见 `speakTrouble`）。
    private enum Trouble: Hashable {
        case probeFailed          // 探针连续失败，判定故障并自愈
        case engineUnstoppable    // stop() 等到超时，旧引擎仍占着端口
        case engineExitAbnormal   // main_from_str 返回 rc≠0
        case engineExitSpurious   // 没人叫它退、它自己退了（恰好 rc=0）
    }

    /// 本次故障期里已经出过声的原因。**故障期由一次成功的探针结束**（见
    /// `endFaultEpisode`）——「好了没有」看「真服务通了」，不看「绑上了」。
    ///
    /// 为什么要去重：本程序是长跑进程（数天不重启），故障期里探针会失败成千上万
    /// 拍、自愈循环上百轮。日志若随重试次数增长，控制台会被刷满、真线索反被淹没
    /// （本仓在 `ReceiverViewController` 的保活重试处已记过同一个坑）。
    private var spokenTroubles: Set<Trouble> = []

    /// 本次故障期累计失败的探针拍数（随故障期清零）。让「已恢复」那一条带上
    /// 「这次故障持续了多久」——不花钱，因为那一行本来就要写。
    private var faultTicks = 0

    /// 自最近一次「判定故障」以来、**未达阈值**的零星失败拍数（设计允许的抖动，
    /// 见 `maxConsecutiveFailures`）。抖动被静默后不该变成盲区，故把它作为字段挂在
    /// 「进入故障」那一条上（`speakTrouble(.probeFailed, …)`）。
    private var blipTicks = 0

    /// 引擎本次启动的时刻，用于「刚起来先别急着判死」（见 `inWarmUp`）。
    private var startedAt: Date?

    /// 预热窗口（秒）：`start()` 返回时 hev 只是被**派发**出去、还没 bind。此刻立刻探针
    /// 必然拿到 ECONNREFUSED，会把「还没起来」判成「引擎无应答」—— 启动那一刻那条误导
    /// 记录就是这么来的（真机上还只写一次、不刷新，用户看到就一直以为坏了）。
    /// 窗口内不探针、也不计失败票。
    private static let warmUpSeconds: TimeInterval = 2.0

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

    /// 启动引擎（只做派发；真正的 hev 循环阻塞在 `queue` 上，见文件头第 2 点）。
    ///
    /// - parameter announce: 是否记一条「已启动」。**自愈重启传 `false`**：那是故障期
    ///   内部的动作，进出两端已经有「进入故障／已恢复」各一条记着，这里再记一次就等于
    ///   让日志随自愈轮数增长（本程序要连跑数天，见 `spokenTroubles`）。
    @discardableResult
    func start(announce: Bool = true) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return true }

        let yaml = Self.configYAML(port: port, bindInterface: bindInterface,
                                   logLevel: logLevel)
        running = true
        startedAt = Date()          // 预热窗口的起点（见 inWarmUp）
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
            // 退出要分清「我们叫它退的」与「它自己没的」：两者旧写法都只留 rc=0 一条，
            // 于是自愈时每轮一条正常退出记录，把「引擎无故自己退出」这条真线索淹掉。
            // 每因一期内只报一次（见 speakTrouble）；应我们所请的正常退出不出声。
            self.lock.lock()
            let askedToQuit = self.quitRequested
            self.quitRequested = false
            self.lock.unlock()
            if rc != 0 {
                self.speakTrouble(.engineExitAbnormal,
                    "[HevSocks] ⚠️ main_from_str 返回 rc=\(rc)（非 0 = 配置、绑定或运行出错）")
            } else if !askedToQuit {
                self.speakTrouble(.engineExitSpurious,
                    "[HevSocks] ⚠️ 引擎自行退出（rc=0，但本对象没有请求过退出）")
            }
        }

        if announce {
            NSLog("[HevSocks] 已启动 127.0.0.1:%d（bind-interface=%@, log=%@）",
                  Int(port), bindInterface.isEmpty ? "<不绑接口>" : bindInterface, logLevel)
        }
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

        lock.lock()
        quitRequested = true       // 见 quitRequested：让退出回调认出「是我们叫的」
        lock.unlock()
        hev_socks5_server_quit()

        // 必须等 main_from_str 真正返回。5s 是经验值：hev 的停止路径是协作式的，
        // 正常情况下 一轮调度内就会退出。
        if group.wait(timeout: .now() + 5) == .timedOut {
            // 每因一期内只报一次：停不掉往往持续存在，而这里是**所有**调用方
            // （看门狗、设置页开关）的公共出口，故日志落在这里、别处不再重复。
            speakTrouble(.engineUnstoppable,
                "[HevSocks] ⚠️ 引擎 5s 内未退出，端口 \(Int(port)) 可能仍被占用")
            return false
        }
        return true
    }

    /// 看门狗自愈入口：探针失败连续 N 次才 stop+start。
    ///
    /// **日志只记状态翻转**（本程序要连跑数天）：单拍/两拍抖动是设计允许的（见
    /// `maxConsecutiveFailures`），全程静默——把正常现象报成故障，比不报还坏。
    /// 整个故障期只在「判定故障」与「真的恢复」两点各出一条，与故障持续多久、
    /// 自愈重试了多少轮无关（见 `speakTrouble` / `endFaultEpisode`）。
    func ensureListening() {
        // 整个「探针 + 可能的重启」都派发到后台队列，主线程完全不阻塞。
        // 见 watchdogQueue / maxConsecutiveFailures 两处注释。
        watchdogQueue.async { [weak self] in
            guard let self else { return }
            // 刚启动的预热窗口内不探：此刻 hev 还没 bind，探针必然失败（见 inWarmUp）。
            guard !self.inWarmUp() else { return }
            // 探针 = 真握手（见 isServing：connect 成功不代表引擎在干活）。
            let serving = self.isServing
            self.publishHealth(serving)          // 结论变化时通知下游（设置页 / 屏上那行）
            guard !serving else {
                self.endFaultEpisode()
                return
            }
            self.lock.lock()
            self.consecutiveFailures += 1
            let n = self.consecutiveFailures
            self.faultTicks += 1
            self.blipTicks += 1
            let blips = self.blipTicks
            self.lock.unlock()
            // 没到阈值 ⇒ 静默。零星抖动的**次数**不丢：它挂在下次「进入故障」那一条上。
            guard n >= self.maxConsecutiveFailures else { return }
            self.resetFailures()
            self.lock.lock()
            let stray = max(0, blips - n)     // 这 n 拍是本轮连续失败，其余是此前的零星抖动
            self.blipTicks = 0
            self.lock.unlock()
            // ①「进入故障」：整个故障期唯一一条，也是下次出事时的取证起点。
            self.speakTrouble(.probeFailed,
                "[HevSocks] ⚠️ 探针连续 \(n) 次失败 → 执行 stop+start 自愈"
                + (stray > 0 ? "（自上次故障以来另有 \(stray) 拍零星失败）" : ""))
            // ★ 停干净才起：旧实例还占着 9001 时硬 start 只会 bind 失败，
            //   留下「端口在、不干活」的死占（见 stop 的说明）。
            guard self.stop() else {
                // 停不掉这件事 stop() 里已经出过声（那里带端口号，且是所有调用方的
                // 公共出口），此处不再重复。下一轮探针会再来（quit() 可重复调用）。
                return
            }
            _ = self.start(announce: false)   // 自愈重启不出声（见 start(announce:)）
        }
    }

    /// 落定一次健康结论，**仅当结论变化时**回调（主队列投递）。
    ///
    /// 三种取值各有含义，别合并：`true` = 真握手通过；`false` = 探针没通过（含
    /// 「端口在、引擎不干活」这个旧探针看不见的状态）；`nil` = 引擎已被停掉。
    private func publishHealth(_ healthy: Bool?) {
        lock.lock()
        let changed = lastHealthy != healthy
        lastHealthy = healthy
        lock.unlock()
        guard changed, let callback = onHealthChange else { return }
        DispatchQueue.main.async { callback(healthy) }
    }

    /// 启动引擎（**异步**）。派发到 watchdogQueue —— 与 `stopAsync` 同一条**串行**队列，
    /// 所以「关掉又立刻打开」不会乱序：主线程直接调 `start()` 的话，它会撞上还没停掉的
    /// 旧实例、`guard !running` 直接返回（看起来启动了，其实什么都没做），紧接着停才生效
    /// ⇒ 引擎死了而开关显示是开的。
    func startAsync(completion: (() -> Void)? = nil) {
        watchdogQueue.async { [weak self] in
            guard let self else {
                if let completion { DispatchQueue.main.async(execute: completion) }
                return
            }
            _ = self.start()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// 停止引擎（**异步**）。`stop()` 内部要 `group.wait(timeout: 5s)`，主线程直接调会把
    /// 界面卡住最多 5 秒，所以必须走这里。停干净后健康结论置 `nil`（引擎都没了，「健不健康」
    /// 不再成立）；若 5s 内没停干净则记为 `false` —— 那正是「端口在、引擎不干活」，
    /// 必须如实报出去，不能伪装成「已关闭」。
    func stopAsync(completion: (() -> Void)? = nil) {
        watchdogQueue.async { [weak self] in
            guard let self else {
                if let completion { DispatchQueue.main.async(execute: completion) }
                return
            }
            // 停不掉这件事由 `stop()` 统一出声（那里带端口号，且覆盖所有调用方）——
            // 同一事实只留一处，这里不再重复刷一条。
            let stopped = self.stop()
            self.publishHealth(stopped ? nil : false)
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// 是否仍在「刚启动」的预热窗口内（见 `warmUpSeconds`）。
    private func inWarmUp() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let startedAt else { return false }   // 从没启动过：交给探针如实报「无应答」
        return Date().timeIntervalSince(startedAt) < Self.warmUpSeconds
    }

    private func resetFailures() {
        lock.lock()
        consecutiveFailures = 0
        lock.unlock()
    }

    /// 报一条故障日志：**同一个故障期内、同一个原因只报一次**（见 `spokenTroubles`）。
    ///
    /// `message` 是 `@autoclosure`：被抑制时连字符串都不拼——探针是一拍拍地跑的，
    /// 这条路径上不能有稳态开销。返回值只表示「这次真报了吗」，不参与控制流。
    @discardableResult
    private func speakTrouble(_ kind: Trouble, _ message: @autoclosure () -> String) -> Bool {
        lock.lock()
        let first = spokenTroubles.insert(kind).inserted
        lock.unlock()
        guard first else { return false }
        NSLog("%@", message())          // 走 %@：消息里的 % 不会被当成格式符
        return true
    }

    /// 故障期结束（探针**真的服务通了**）。这是唯一清账的地方 ⇒ 下一轮故障会重新出声；
    /// 顺带把累计失败拍数补进一条「已恢复」记录——那一行本来就要写，加个字段就把
    /// 「这次故障持续了多久」从 N 行压成了 1 行。
    ///
    /// 用「真握手通了」而不是「绑上了」判恢复：端口在、引擎不干活时探针通不过，
    /// 此时若清了账，两天后真出事时日志会重新刷屏（本仓吃过这个假正常态的亏）。
    private func endFaultEpisode() {
        lock.lock()
        let wasSpoken = !spokenTroubles.isEmpty
        let ticks = faultTicks
        spokenTroubles.removeAll()
        faultTicks = 0
        consecutiveFailures = 0
        lock.unlock()
        guard wasSpoken else { return }      // 一直健康：静默（稳态零日志）
        NSLog("[HevSocks] ✅ 引擎探针已恢复（本次故障累计 %d 拍失败）", ticks)
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
          # nofile 是 server 端唯一的并发天花板（无 max-session-count）：每条被代理
          # 的 TCP 会话耗 2 个 fd（客户端＋出站），512 ⇒ 并发上限约 253。Mac 侧
          # hev-socks5-tunnel 的 max-session-count 是 1024，且其读写超时已放宽到
          # 5 分钟（长连接并发上升）——本值 2048（上限约 1020）与之对齐。
          # setrlimit 撞 iOS 硬上限时只是失败并留一条 WARN，实际停留在系统允许
          # 的最大值，不会比旧值更差。
          limit-nofile: 2048
        """
    }
}
