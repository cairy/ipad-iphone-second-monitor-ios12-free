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
// 稳定性纪律（超长运行场景，见设计讨论 2026-10-09）：
//   - 空闲零成本：被动监听 socket 是内核对象，无人连接时零唤醒、零 CPU；
//   - 无状态：payload 在启动时按解析结果拼好一份常量 Data，每次连接只是 send+close；
//   - 无写盘、无时钟读取（剩余天数由 Mac 侧用绝对时刻现算）；
//   - 一切异常自吞：应答点坏了就关掉重试（有界退避），绝不影响隧道引擎。

import Foundation

// MARK: - 解析 embedded.mobileprovision

/// 三态：无此文件（商店/TestFlight 签名）/ 解析成功 / 有文件但读不出来。
/// 绝不拿 0 或「无限期」顶替失败——那是 Mac 端显示口径的承重墙。
enum SignatureExpiry {
    case absent
    case expires(Date)
    case unreadable

    static func load(bundle: Bundle = .main) -> SignatureExpiry {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return .absent }
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
    /// 绑定失败的重试退避：1s 起，翻倍封顶 30s。成功监听后复位。
    private var retryDelay: TimeInterval = 1

    init(port: UInt16 = 9002, payload: Data) {
        self.port = port
        self.payload = payload
    }

    func start() {
        queue.async { [weak self] in self?.armLocked() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listenSource?.cancel()
            self?.listenSource = nil
        }
    }

    // 以下都在 queue 上跑。

    private func armLocked() {
        guard listenSource == nil else { return }
        guard let fd = Self.makeListener(port: port) else {
            NSLog("[Announce] ⚠️ 127.0.0.1:%u 监听失败，%.0fs 后重试", UInt(port), retryDelay)
            scheduleRetryLocked()
            return
        }
        retryDelay = 1
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drainConnections(fd) }
        src.setCancelHandler { close(fd) }
        src.resume()
        listenSource = src
        NSLog("[Announce] 127.0.0.1:%u 已监听（连接即倾倒签名到期信息）", UInt(port))
    }

    private func scheduleRetryLocked() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
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
            guard cfd >= 0 else { break }   // EAGAIN：没有更多了
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
        }
    }

    private static func makeListener(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            return nil
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return fd
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
