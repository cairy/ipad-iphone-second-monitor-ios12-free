// ControlChannel.swift
//
// Mac → iPad 的私有控制通道（与视频/OpenDisplay 的 9000 完全独立）。
//
// 用途：Mac 锁屏联动。BarKit（Mac 侧，ipad_tunnel/locksync.py）在锁屏状态
// 变化时经 usbmuxd 连到本端口，发一条 length-prefixed JSON：
//   {"type": "macLock", "locked": 1|0}
// iPad 收到后黑屏（隐藏视频层）防内容外泄；解锁恢复并强制重连视频流。
//
// 为什么不搭 9000 的便车：9000 的连接由第三方 OpenDisplay App 持有，且
// VideoReceiver.newConnectionHandler 会踢掉旧连接——BarKit 若连上去会把
// 视频流顶掉。独立端口 = 两条通道互不干扰。
//
// 端口约定：9002（与 barkit locksync.py 的 CONTROL_PORT 一一对应）。
// 仅绑定 loopback：和 9001 的 SOCKS 一样，usbmuxd 转发可达，Wi-Fi 不可达。

import Foundation
import Network

protocol ControlChannelDelegate: AnyObject {
    /// 主线程回调。locked = Mac 侧锁屏状态。
    func controlChannel(_ channel: ControlChannel, macLockedDidChange locked: Bool)
}

final class ControlChannel {

    weak var delegate: ControlChannelDelegate?

    /// 副屏会话状态提供者（主线程调用）：返回 true 表示视频会话处于睡眠。
    /// ReceiverViewController 用它把唯一状态机的结果回报给 Mac，
    /// BarKit 面板据此显示"副屏活跃/睡眠"。
    var sleepingProvider: (() -> Bool)?

    static let port: UInt16 = 9002

    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "controlchannel.queue")
    private var buffer = Data()
    private(set) var isRunning = false

    func start() {
        queue.async { [weak self] in self?.startListener() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
            self.buffer.removeAll()
            self.isRunning = false
        }
    }

    private func startListener() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true   // 控制消息是几十字节的实时信号，绝不能让 Nagle 攒着
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        // 只听 loopback：usbmuxd 转发从设备内部进来，走得到 127.0.0.1；
        // Wi-Fi 上的其他设备摸不到这个端口。
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: Self.port)!)

        do {
            listener = try NWListener(using: params)
        } catch {
            NSLog("[ControlChannel] 监听 127.0.0.1:%d 失败：%@", Self.port, error.localizedDescription)
            return
        }

        listener?.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            // 单连接语义：新连接顶掉旧连接（Mac 侧每次都是短连接，正常不会撞）。
            self.connection?.cancel()
            self.connection = conn
            self.buffer.removeAll()
            conn.stateUpdateHandler = { state in
                if case .failed(let e) = state {
                    NSLog("[ControlChannel] 连接失败：%@", e.localizedDescription)
                }
            }
            conn.start(queue: self.queue)
            self.receive(on: conn)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.isRunning = true
                NSLog("[ControlChannel] 已监听 127.0.0.1:%d（Mac 锁屏联动通道）", Self.port)
            case .failed(let error):
                NSLog("[ControlChannel] 监听失败：%@ -- 1s 后重试", error.localizedDescription)
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.listener?.cancel()
                    self?.listener = nil
                    self?.startListener()
                }
            default:
                break
            }
        }
        listener?.start(queue: queue)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                self.drainFrames()
            }
            if error != nil || isComplete { return }
            self.receive(on: conn)
        }
    }

    /// 帧格式与视频通道一致：4 字节大端长度 + JSON。
    private func drainFrames() {
        while buffer.count >= 4 {
            let len = buffer.prefix(4).withUnsafeBytes { raw -> Int in
                let b = raw.bindMemory(to: UInt8.self)
                return Int((UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3]))
            }
            guard len > 0, len < 1 << 20, buffer.count >= 4 + len else {
                if len <= 0 || len >= 1 << 20 {
                    // 非法长度：缓冲区已错位，丢弃重来（保守自愈）。
                    NSLog("[ControlChannel] 非法帧长 %d，重置缓冲", len)
                    buffer.removeAll()
                }
                return
            }
            let payload = buffer.subdata(in: 4..<(4 + len))
            buffer.removeSubrange(0..<(4 + len))
            handleJSON(payload)
        }
    }

    private func handleJSON(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "macLock":
            let locked = (obj["locked"] as? Int ?? 0) == 1
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.controlChannel(self, macLockedDidChange: locked)
                // 顺路回报副屏会话状态（发送端是短连接，回完即关）。
                let sleeping = self.sleepingProvider?() ?? true
                self.queue.async { [weak self] in
                    self?.sendReply(["type": "state", "sleeping": sleeping ? 1 : 0])
                }
            }
        default:
            break
        }
    }

    /// 回报帧（与入站相同的 4 字节大端长度 + JSON），发给当前连接；
    /// 连接已关则静默丢弃——回报是增益项。
    private func sendReply(_ message: [String: Any]) {
        guard let conn = connection,
              let payload = try? JSONSerialization.data(withJSONObject: message) else { return }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }
}
