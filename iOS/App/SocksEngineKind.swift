// SocksEngineKind.swift
//
// 两个 SOCKS5 引擎共用的接口 + 引擎选择。
//
// 为什么要保留两套：microsocks 是 thread-per-connection，hev-socks5-server
// 是「多 worker + 协程」。升级的核心假设是后者在 iPad mini 4（A8 双核）上
// 更省资源，但这个假设必须先验证——见规格 2.2 的温度对照。两套并存才能在
// 同一台设备上直接 A/B，而不用反复重新编译安装。

import Foundation

/// ReceiverViewController 唯一依赖的抽象。
///
/// `isListening` 在两个引擎下**都是真实端口探针**，能发现 iOS 在后台回收了
/// 监听 socket 的情况（而不是只记「我调过 start」）：
/// - microsocks 走 `socksbridge_is_running()`（C 侧 g_state 探测）；
/// - hev 走 `HevSocksProxy.isListening`：一次带 0.3s 超时的回环 TCP connect，
///   端口真死才超时返回 false，触发看门狗 stop+start 自愈。
/// 两者都已从 `Timer`（主线程）移出到后台 watchdog 队列，探针/重启都不卡 UI。
protocol SocksProxying: AnyObject {
    /// 引擎**当前是否真的在服务**，而不是「我调过 start()」的记忆。
    /// - microsocks 读 C 侧状态（`socksbridge_is_running()`）；
    /// - hev 做一次带超时的回环 connect 探针。
    /// 两者都能发现 iOS 在后台回收了监听 socket 的情况。
    var isListening: Bool { get }
    /// 供状态栏显示
    var engineName: String { get }
    @discardableResult func start() -> Bool
    /// 后台自愈：探针失败（连续多次）则 stop+start。
    /// - parameter token: 自愈令牌。真正执行重启前会先校验 `token.isValid`；
    ///   引擎切换会作废旧令牌，避免「派发后才开始的切换」让后台块把已停用的
    ///   旧引擎重新拉起、抢回 9001（见 ReceiverViewController.handleEngineSwap）。
    func ensureListening(_ token: SocksRestartToken)
    func stop()
}

/// 自愈令牌：把「这一次自愈还算不算数」的决定权交给调用方。
///
/// 为什么需要：看门狗在主线程派发自愈任务到后台队列，而「引擎切换中」这个
/// 标志是在派发**之前**检查的。若切换在这段窗口内开始，后台块拿到的仍是旧
/// 引擎引用，重启后旧引擎会重新占住 9001，新引擎再 start 就会失败——而
/// `HevSocksProxy.start()` 只保证"已派发"、不保证绑定成功，UI 会显示切换
/// 成功、实际仍在跑旧引擎。令牌让后台块在执行重启前再确认一次。
final class SocksRestartToken {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    /// 作废。已派发的后台任务会在重启前看到失效并放弃。
    func invalidate() {
        lock.lock()
        valid = false
        lock.unlock()
    }
}

enum SocksEngine: Equatable {
    case microsocks
    case hev

    var displayName: String {
        switch self {
        case .microsocks: return "microsocks"
        case .hev: return "hev"
        }
    }

    /// 编译期默认引擎。当前默认 hev（协程版，规格 2.2 要验的温度/资源账）。
    ///
    /// 运行期切换用三指长按（见 ReceiverViewController），会覆盖这个值，
    /// 但不会持久化——重启 App 回到这里。要回退到 microsocks 只需把下面
    /// 改回 `.microsocks`。
    static let defaultEngine: SocksEngine = .hev

    func makeProxy(port: UInt16) -> SocksProxying {
        switch self {
        case .microsocks: return SocksProxy(devicePort: port)
        case .hev: return HevSocksProxy(port: port)
        }
    }
}
