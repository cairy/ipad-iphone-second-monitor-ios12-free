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

final class SocksProxy {

    private let devicePort: UInt16
    private var started = false
    private let lock = NSLock()

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
    func ensureListening() {
        lock.lock()
        defer { lock.unlock() }
        if started && socksbridge_is_running() != 0 { return }
        if started {
            socksbridge_stop()
            started = false
        }
        _ = startLocked()
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
