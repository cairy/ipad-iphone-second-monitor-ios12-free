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
/// 注意 `isListening` 的语义在两个引擎下强度不同：
/// - microsocks 有 `socksbridge_is_running()`，是真实探针，能发现 iOS 在
///   后台回收了监听 socket 的情况；
/// - hev 没有对应 API，只能退化为「引擎循环还在跑」。
protocol SocksProxying: AnyObject {
    /// 引擎是否在运行。hev 下这是「循环还活着」而非真实端口探针。
    var isListening: Bool { get }
    /// 供状态栏显示
    var engineName: String { get }
    @discardableResult func start() -> Bool
    func ensureListening()
    func stop()
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
