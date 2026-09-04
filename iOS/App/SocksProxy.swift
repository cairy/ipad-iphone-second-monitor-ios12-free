// SocksProxy.swift
//
// Thin Swift wrapper around the embedded microsocks SOCKS5 server
// (see App/SocksEngine). The server is a long-running C accept loop; this
// class exposes a Swift-friendly start/ensureListening API and, crucially,
// keeps it INDEPENDENT of the video listener. ReceiverViewController's
// foreground-reconnect logic tears down and recreates the video NWListener on
// every return to the foreground -- if the SOCKS server lived on that same
// path it would be killed too. Here it owns its own lifecycle.

import Foundation

final class SocksProxy: SocksProxying {

    private let devicePort: UInt16
    private var started = false
    private let lock = NSLock()

    /// 看门狗自愈后台队列（见 ensureListening）。microsocks 的探针是「读运行
    /// 标志」而非超时 connect，本身很快，但仍统一放后台，主线程零阻塞。
    private let watchdogQueue = DispatchQueue(label: "com.example.microsocks-watchdog", qos: .utility)

    /// 连续探针失败次数。microsocks 读的是运行标志，不会因负载误判，但仍要
    /// 连续多次失败才重启，避免偶发竞态把正在服务的实例重启。
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3

    var engineName: String { "microsocks" }

    /// 与 sockssrv.c 的 `enum microsocks_state` 一一对应，改 C 侧必须同步改这里。
    private enum State: Int32 {
        case idle = 0, starting, running, stopped, failed
    }

    /// `devicePort` is the TCP port microsocks listens on, inside the iPad.
    /// The Mac side forwards to it over USB via usbmuxd (see mac_socks_bridge.py).
    init(devicePort: UInt16 = 9001) {
        self.devicePort = devicePort
    }

    /// True only when the accept loop is actually live and listening.
    ///
    /// This is a live probe, not a memory of having called `start()`. The
    /// distinction matters: iOS may reclaim the listening socket while we are
    /// backgrounded, and the old code had no way to notice -- it kept reporting
    /// "started" while every connection was refused.
    ///
    /// 这里刻意不加 `lock`：`devicePort` 是 `let`，C 侧的 `g_state` / `g_running`
    /// 都是 volatile，读一次本身就是一份原子快照；加锁反而容易让人以为它和
    /// `started` 这个记忆值有关——判断只看 C 侧真相，不掺 `started`。
    var isListening: Bool {
        return socksbridge_is_running() != 0
    }

    /// Launch the SOCKS server exactly once. Idempotent and thread-safe.
    /// Returns false if the listen socket could not be created (port already
    /// bound, or iOS refused the bind) -- callers should log/surface this
    /// rather than assuming the proxy is up.
    @discardableResult
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return startLocked()
    }

    /// Called from the app's will-enter-foreground hook.
    ///
    /// Previously a no-op, which meant that if iOS had reclaimed the listening
    /// socket during a long background the proxy stayed dead until the app was
    /// relaunched by hand. Now: if the loop is still live we do nothing, and
    /// if it died we stop cleanly (releasing the port) and start again.
    func ensureListening(_ token: SocksRestartToken) {
        // 探针 + 可能的重启都派发到后台，主线程零阻塞（见 watchdogQueue 注释）。
        watchdogQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = self.started && socksbridge_is_running() != 0
            self.lock.unlock()
            if live {
                self.resetFailures()
                return
            }
            self.lock.lock()
            self.consecutiveFailures += 1
            let n = self.consecutiveFailures
            self.lock.unlock()
            // 带上 C 侧状态一并打印：MSOCKS_FAILED(4) 意味着监听 socket 被系统
            // 回收而异常死亡，与「被显式停止」(3) 是两回事，必须能在日志里分开。
            let st = socksbridge_state()
            NSLog("[SocksProxy] 探针失败（连续 %d/%d 次，state=%d%@）",
                  n, self.maxConsecutiveFailures, st,
                  (st == State.failed.rawValue
                   ? " ⚠️监听 socket 失效（异常死亡，非主动停止）" : ""))
            guard n >= self.maxConsecutiveFailures else { return }
            // 切换引擎会作废旧令牌：此时旧引擎已被停用，拉起来只会抢回 9001。
            guard token.isValid else {
                NSLog("[SocksProxy] 自愈令牌已失效（引擎切换中），放弃本次重启")
                return
            }
            self.lock.lock()
            self.consecutiveFailures = 0
            if self.started {
                socksbridge_stop()
                self.started = false
            }
            _ = self.startLocked()
            self.lock.unlock()
        }
    }

    private func resetFailures() {
        lock.lock()
        consecutiveFailures = 0
        lock.unlock()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        socksbridge_stop()
        started = false
    }

    // MARK: - Private (callers must hold `lock`)

    @discardableResult
    private func startLocked() -> Bool {
        guard !started else { return socksbridge_is_running() != 0 }
        let rc = socksbridge_start(devicePort)
        started = (rc == 0)
        if rc != 0 {
            NSLog("[SocksProxy] 启动失败 rc=%d（端口 %d 可能被占用或绑定被拒）",
                  rc, Int(devicePort))
        } else {
            /* Success used to be silent, which made the console useless for
               answering "is the proxy up?": you had to infer it from the
               absence of an error, and microsocks itself runs with -q. Note
               that a failed server_setup() does reach the console on its own
               (sockssrv.c calls perror(), which bypasses the -q flag), so this
               line is the positive half of that pair. */
            NSLog("[SocksProxy] 已监听 127.0.0.1:%d（usbmuxd 设备端口，Mac 侧转发至此）",
                  Int(devicePort))
        }
        return started
    }
}
