// SignatureAnnounce.swift
//
// 签名有效期：解析 + 通告 + 设置页显示，三件事共享一次解析。
//
// 背景：本 App 用个人证书签名（免费开发者描述文件 7 天一签）。过期后 App 无法
// 再次启动；若一直留在前台，进程可能仍活着（但行为已属系统未文档化的例外，
// 伴随降速——见 2026-10-09 讨论）。Mac 端的 ipad_tunnel 插件想知道「还剩几天」，
// 只能让 App 自己说：SOCKS5 协议（hev）没有放元数据的地方，hev 是第三方引擎
// 不能改，所以 App 在设备回环上开一个「连接即倾倒」的应答点，Mac 经 usbmuxd
// 直连来读（与 9001 同暴露面：只绑 127.0.0.1）。
//
// 稳定性纪律（超长运行场景，见设计讨论 2026-10-09 / 2026-10-11）：
//   - 空闲零成本：被动监听 socket 是内核对象，无人连接时零唤醒、零 CPU；
//   - 无状态：payload 在启动时按解析结果拼好一份常量 Data，每次连接只是 send+close；
//   - 无写盘、无时钟读取（剩余天数由 Mac 侧用绝对时刻现算）；
//   - 一切异常自吞，但日志**只在状态翻转时出声**：一次故障会连着好几轮重试/重绑，
//     故一律「进入故障 1 条 ＋ 离开故障 1 条」，中间的重试与同因重复失败静默
//     （见 announceTrouble / logTroubleOnce）。NSLog 只进系统统一日志（系统循环缓冲
//     管理、超期自动回收），App 自己不建日志文件、不占盘。
//   - 自愈 = 唤醒重建：绑定只发生在「启动」与「App 回前台 / 解锁」两处（见
//     `SignatureAnnounce.rearm`）。刻意**不**做「先探再修」——同一个故障会连探针
//     一起带走，而重建是廉价且顺序确定的动作。（2026-10-11：监听被唤醒边界收走后
//     整天回不来，且不留一条日志。）
//   - accept 出错**不卸监听**：2026-10-11 实测，本平台的 DispatchSourceRead 是边沿
//     触发（旧写法在 EMFILE 窗口里进入次数仍为 1、CPU 0.000s，**不空转**），且下一次
//     连接到来会重新触发 accept ⇒ 端口自愈。所以这里只做两件事：把 errno 分层
//     （EAGAIN = 正常 / EINTR = 重试 / 其余 = 故障），并把故障**记一条** —— 旧写法把
//     三者揉成同一个静默 `break`，出事时零线索。只有**绑定失败**才走「卸下重绑 +
//     有界退避」（那时端口是真的不在了）。

import Foundation

// MARK: - 解析 embedded.mobileprovision

/// 三态：无此文件（商店/TestFlight 签名）/ 解析成功 / 有文件但读不出来。
/// 绝不拿 0 或「无限期」顶替失败——那是 Mac 端显示口径的承重墙。
enum SignatureExpiry {
    case absent
    case expires(Date)
    case unreadable

    static func load(bundle: Bundle = .main) -> SignatureExpiry {
        // 「没有这个文件」与「有这个文件却读不出来」必须**分开**：合成一条 guard 会把
        // 读失败也报成 `.absent`，而 `.absent` 在 Mac 侧显示的是「无签名档案（商店/
        // TestFlight 分发，无到期问题）」——那是本文件最忌讳的假安心话。
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision") else {
            return .absent
        }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        // mobileprovision = CMS(DER) 包着一段 XML plist。不必解 CMS：
        // 截取 <?xml … </plist> 字节段交给 PropertyListSerialization。
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              start.lowerBound < end.upperBound,
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound),
                  options: [], format: nil) as? [String: Any],
              let expiry = plist["ExpirationDate"] as? Date else { return .unreadable }
        return .expires(expiry)
    }
}

// MARK: - 9002 应答点（连接即倾倒）

/// 监听 127.0.0.1:9002：CONNECT 一通就写出常量 JSON 然后 close。
/// 不读请求、不解析、无 keep-alive——客户端只有 Mac 探针一个，协议天生私有
/// （version 字段从第一天就带，将来演进靠它协商）。
final class AnnounceResponder {
    private let port: UInt16
    private let payload: Data
    private let queue = DispatchQueue(label: "announce.responder", qos: .utility)
    private var listenSource: DispatchSourceRead?
    /// 有人要求重建时置位；真正的重绑在「取消回调」里做（那时旧 fd 已关），
    /// 见 rearmLocked / afterDisarmLocked。只在 queue 上读写。
    private var rearmPending = false
    /// 是否处在「已报过故障、尚未真正服务成功」的期间。它**只由一次成功的应答清除**
    /// （不是「绑上了」就清——绑上只说明端口在，不说明能应答）。用来把日志压成
    /// 「进入故障 1 条 ＋ 离开故障 1 条」，防超长运行下被反复重试刷屏。
    private var announceTrouble = false
    /// 本次武装的来由，只用于日志（启动 / 唤醒重建 / 退避重试）。只在 queue 上读写。
    private var armCause = "启动"
    /// 绑定失败的重试退避：1s 起，翻倍封顶 30s。成功监听后复位。
    private var retryDelay: TimeInterval = 1

    init(port: UInt16 = 9002, payload: Data) {
        self.port = port
        self.payload = payload
    }

    func start() {
        queue.async { [weak self] in self?.armLocked() }
    }

    /// **无条件**重建监听。App 回前台 / 解锁时调（见 SignatureAnnounce.rearm）。
    func rearm() {
        queue.async { [weak self] in self?.rearmLocked() }
    }

    // 以下都在 queue 上跑。

    private func armLocked() {
        // 幂等守卫。清空只发生在一处：afterDisarmLocked（重建路径）—— 旧写法靠
        // `stop()` 清，而 stop() 全仓没有调用方 ⇒ 监听 fd 一旦被收走就**永不再绑**，
        // 且不报错（2026-10-11 事故：9002 死了整整一天）。
        guard listenSource == nil else { return }
        let (maybeFD, bindErrno) = Self.makeListener(port: port)
        guard let fd = maybeFD else {
            logTroubleOnce("[Announce] ⚠️ 127.0.0.1:\(port) 监听失败（errno \(bindErrno): "
                + "\(String(cString: strerror(bindErrno)))），\(Int(retryDelay))s 后按有界退避重试")
            scheduleRetryLocked()
            return
        }
        retryDelay = 1
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drainConnections(fd) }
        // 关 fd 只在这一处；重建的「绑新」也接在这里：取消回调必然排在在飞的
        // 读事件之后、且与本类同在一条串行队列 ⇒「关旧 → 绑新」顺序确定，
        // 新 bind 不会撞上还没关掉的旧 fd（EADDRINUSE）。
        src.setCancelHandler { [weak self] in
            close(fd)
            self?.afterDisarmLocked()
        }
        src.resume()
        listenSource = src
        // 故障期间不记这条：那时它每轮退避都会重复一次（超长运行下会刷屏），而
        // 「真的好了」由 drainConnections 里那条「已恢复」负责说明。
        if !announceTrouble {
            log("[Announce] 127.0.0.1:\(port) 已监听（\(armCause)；连接即倾倒签名到期信息）")
        }
    }

    /// 重建请求：旧监听还在就设旗，重绑交给取消回调（顺序确定，见 armLocked）。
    private func rearmLocked() {
        armCause = "唤醒重建"
        guard listenSource != nil else {
            // 还没绑上（或正处在退避重试中）：立刻再试一次，不必等退避。
            armLocked()
            return
        }
        rearmPending = true
        listenSource?.cancel()
    }

    /// 旧监听已卸下（fd 已关）之后调用。只在 queue 上跑。
    private func afterDisarmLocked() {
        listenSource = nil
        guard rearmPending else { return }
        rearmPending = false
        armLocked()
    }

    private func scheduleRetryLocked() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        armCause = "退避重试"
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.armLocked() }
    }

    /// 排干所有待接受连接：每个都是「写出 → 关闭」。send 失败（Mac 侧先断开）
    /// 只说明这次没人听，不值得记——应答点的失败不构成任何人的信号。
    private func drainConnections(_ fd: Int32) {
        while true {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let cfd = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(fd, sa, &len)
                }
            }
            if cfd < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK { break }   // 正常：没有更多连接了
                if err == EINTR { continue }                        // 被信号打断：再来一次
                // 真错误（EMFILE/ENFILE/ENOBUFS…）。**不卸监听**：这个 source 是边沿
                // 触发的（2026-10-11 实测：本窗口内进入次数 1、CPU 0.000s，原地不重入），
                // 而下一次连接到来会重新触发 accept ⇒ 端口自愈。旧写法把「出错」和
                // 「没有更多」揉成同一个静默 `break`，出事时零线索——这里至少记一条，
                // 且一次故障只记一次（见 logTroubleOnce）。
                logTroubleOnce("[Announce] ⚠️ 127.0.0.1:\(port) accept 失败（errno \(err): "
                    + "\(String(cString: strerror(err)))）· 该连接无人应答，端口继续服务")
                break
            }
            payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard var p = raw.baseAddress else { return }
                var remaining = raw.count
                while remaining > 0 {
                    let n = send(cfd, p, remaining, 0)
                    if n <= 0 { break }
                    p += n
                    remaining -= n
                }
            }
            close(cfd)
            // 真服务成功过一次 ⇒ 本次故障期结束。判据落在「服务成功」而不是「绑成功」
            // 上：绑上只说明端口在，不说明能应答。
            if announceTrouble {
                announceTrouble = false
                log("[Announce] 127.0.0.1:\(port) 已恢复（故障后首次应答成功）")
            }
        }
    }

    // MARK: - 日志（超长运行：只在状态翻转时出声）

    private func log(_ message: @autoclosure () -> String) {
        NSLog("%@", message() as NSString)
    }

    /// 「进入故障」的唯一出口：本次故障期里第一次出错记一条，之后一律静默。
    /// 收 autoclosure 是有意的：被抑制时连字符串都不拼（这是本文件唯一的热点）。
    private func logTroubleOnce(_ message: @autoclosure () -> String) {
        guard !announceTrouble else { return }
        announceTrouble = true
        NSLog("%@", message() as NSString)
    }

    // MARK: - 监听 fd

    /// 建监听 fd。失败时把 errno 一并带出来——日志必须说清是 EADDRINUSE 还是 EMFILE。
    private static func makeListener(port: UInt16) -> (Int32?, Int32) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return (nil, errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Darwin：accepted socket **继承**监听 fd 的 SO_NOSIGPIPE ⇒ 设这一处即覆盖之后
        // 所有连接。没有它，向已断开的 peer `send()` 会抛 SIGPIPE，而 Darwin 的默认
        // 处置是**终止进程**——可本文件的应答语义恰恰是「send 失败只说明这次没人听，
        // 不值得记」（见 drainConnections）。全 App 没有别处忽略 SIGPIPE：hev 只在它的
        // `main()` 里装 SIGINT，而 iOS 上走的是 API 入口，那个 `main()` 根本不执行。
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 || listen(fd, 4) != 0 {
            let e = errno
            close(fd)
            return (nil, e)
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return (fd, 0)
    }
}

// MARK: - 组装（解析一次 → 常量 payload → 应答点 + 设置页 defaults）

enum SignatureAnnounce {
    /// 设置页那一行读的 defaults 键（Root.plist 同名）。
    static let settingsKey = "sign_expiry_text"
    static let announcePort: UInt16 = 9002

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    /// 常驻持有：GCD 源不保活 self，引用掉了应答点就静默消失。
    private static var keeper: AnnounceResponder?

    /// App 启动时调一次。重签 + 重装本来就要重启 App，快照自然跟着更新。
    static func start(now: Date = Date()) {
        let expiry = SignatureExpiry.load()
        let text = settingsText(expiry, now: now)
        let defaults = UserDefaults.standard
        if defaults.string(forKey: settingsKey) != text {
            defaults.set(text, forKey: settingsKey)
        }
        let responder = AnnounceResponder(port: announcePort, payload: payload(expiry, now: now))
        keeper = responder
        responder.start()
        // 常驻到进程结束：应答点没有停机场景（App 退出即随进程消失）。
    }

    /// 唤醒（回前台 / 解锁）时重新武装应答点。**这是本功能唯一的自愈路径。**
    ///
    /// 为什么必须有：唤醒边界（锁屏→解锁、拔插 USB 后进程被挂起再回来）会把进程里
    /// 的监听一起收走 —— 9000 靠 `ensureListening()` 无条件重建、9001 靠 8s 看门狗，
    /// 只有 9002 什么都没有 ⇒ 2026-10-11 事故里 9001 一路正常、9002 死了整整一天，
    /// 而 Mac 侧只在链路翻上来那一次读它，于是整天读不到。
    ///
    /// 为什么是无条件重建而不是「先探再修」：探针要另起队列、要有超时、还要验真
    /// 应答，成本远高于拆旧绑新两个内核调用；而重建窗口（微秒级）内不会有客户端来
    /// 连它（Mac 只在链路翻上来那一次读）。给一个非主要功能加探测链不划算。
    static func rearm() {
        keeper?.rearm()
    }

    /// 设置页那一行的**唯一文案出口**（Root.plist 只显示，不自己拼）。
    static func settingsText(_ e: SignatureExpiry, now: Date = Date()) -> String {
        switch e {
        case .absent:
            return "无签名档案（商店/TestFlight 分发，无到期问题）"
        case .unreadable:
            return "签名档案读不出来"
        case .expires(let d):
            let date = day.string(from: d)
            let days = Calendar.current.dateComponents([.day], from: now, to: d).day ?? 0
            if days < 0 { return "已到期（\(date)）· 进程仍活着，重启即失效" }
            if days == 0 { return "今天到期（\(date)）· 尽快重签" }
            return "还剩 \(days) 天（\(date) 到期）"
        }
    }

    /// 常量 JSON：state / expires_at（绝对时刻）/ announced_at（写方自陈时刻）。
    /// 剩余天数不进协议——设备间时钟不同步时相对值必错，Mac 侧自己算。
    static func payload(_ e: SignatureExpiry, now: Date = Date()) -> Data {
        var obj: [String: Any] = ["version": 1, "announced_at": iso.string(from: now)]
        switch e {
        case .absent:
            obj["state"] = "absent"
        case .unreadable:
            obj["state"] = "unreadable"
        case .expires(let d):
            obj["state"] = "ok"
            obj["expires_at"] = iso.string(from: d)
        }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }
}
